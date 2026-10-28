# Agent Observability & Security Runbook (Google Cloud ADK, Agent Topology & SCC AI Protection)

This runbook consolidates all steps required to instrument, register, observe, and secure a multi-agent system spanning **Vertex AI Agent Runtime** (`github-agent`) and **Cloud Run** (`salesforce-agent`) with an external **GitHub MCP Server** (`github-mcp`).

---

## Architecture Overview

```
User / CLI
  ├──> github_agent (Vertex AI Agent Runtime)
  │      └──> GitHub MCP Server (https://api.githubcopilot.com/mcp/ - JSON-RPC)
  └──> salesforce_agent (Cloud Run - A2A Protocol)
         └──> Salesforce REST/SOSL API
```

- **Distributed Tracing**: OpenTelemetry (`google-adk[gcp,otel-gcp]`) exports spans (`invocation`, `invoke_agent`, `call_llm`, `generate_content`, `execute_tool`) to `telemetry.googleapis.com` / Cloud Trace using `roles/telemetry.tracesWriter`.
- **Discovery & Inventory**:
  - `github-agent` on Vertex AI Agent Runtime is auto-discovered by **Agent Registry** and **App Hub**.
  - `salesforce-agent` on Cloud Run is manually registered in **Agent Registry** using its A2A Agent Card (`/.well-known/agent-card.json`).
  - `github-mcp` is manually registered in **Agent Registry** as an external MCP server and correlated with traces via the `gcp.mcp.server.destination.id` metadata attribute.
- **Posture & Least Privilege**: **Security Command Center (SCC) AI Protection** and **Cloud Asset Inventory Policy Analyzer** identify and remediate over-privileged agent service accounts.

---

## Task 1: Set Environment Variables & Enable APIs

### 1.1 Configure Project, Location, and Organization Variables

```bash
export PROJECT_ID=$(gcloud config get-value project)
export PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")
export LOCATION="us-central1"
export ORGANIZATION_ID=$(gcloud projects get-ancestors "${PROJECT_ID}" --format=json | jq -r '.[] | select(.type=="organization") | .id')

echo "PROJECT_ID:      ${PROJECT_ID}"
echo "PROJECT_NUMBER:  ${PROJECT_NUMBER}"
echo "LOCATION:        ${LOCATION}"
echo "ORGANIZATION_ID: ${ORGANIZATION_ID}"
```

### 1.2 Pull Agent Code from Cloud Storage

```bash
cd ~
gcloud storage cp -r "gs://${PROJECT_ID}-bucket/apex_labs" .
gcloud storage cp -r "gs://${PROJECT_ID}-bucket/agents" .
mkdir -p ~/.vscode
gcloud storage cp "gs://${PROJECT_ID}-bucket/settings.json" ~/.vscode/settings.json
```

### 1.3 Enable Observability, Discovery, and Runtime APIs

```bash
gcloud services enable \
  observability.googleapis.com \
  cloudtrace.googleapis.com \
  telemetry.googleapis.com \
  apphub.googleapis.com \
  apptopology.googleapis.com \
  agentregistry.googleapis.com \
  cloudasset.googleapis.com \
  monitoring.googleapis.com \
  logging.googleapis.com \
  aiplatform.googleapis.com \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  --project="${PROJECT_ID}"
```

### 1.4 Install `agents-cli`

```bash
uv tool install google-agents-cli==1.12.0
export PATH="$HOME/.local/bin:$PATH"
agents-cli --version
```

### 1.5 (If Starting in a Fresh Lab Environment) Deploy Prerequisite Agents

If `salesforce-agent` (Cloud Run) and `github-agent` (Agent Runtime) are not yet deployed in the project:

```bash
# Grant base runtime roles to the default compute service account
for ROLE in roles/aiplatform.user roles/logging.logWriter roles/cloudtrace.agent; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --role="${ROLE}" \
    --quiet
done

# Deploy salesforce-agent to Cloud Run
gcloud run deploy salesforce-agent \
  --source ~/agents/salesforce-agent \
  --region "${LOCATION}" \
  --project "${PROJECT_ID}" \
  --no-allow-unauthenticated \
  --memory 4Gi \
  --min-instances 1 \
  --max-instances 10 \
  --concurrency 80 \
  --timeout 300 \
  --set-env-vars="GOOGLE_CLOUD_PROJECT=${PROJECT_ID},GOOGLE_CLOUD_LOCATION=global,GOOGLE_GENAI_USE_VERTEXAI=True,MODEL=gemini-2.5-flash,SALESFORCE_DOMAIN=${SALESFORCE_DOMAIN:-example.my.salesforce.com},SALESFORCE_CLIENT_ID=${SALESFORCE_CLIENT_ID:-dummy_client_id},SALESFORCE_CLIENT_SECRET=${SALESFORCE_CLIENT_SECRET:-dummy_client_secret},AGENT_VERSION=0.1.0,APP_URL=https://salesforce-agent-${PROJECT_NUMBER}.${LOCATION}.run.app" \
  --quiet

# Deploy github-agent to Vertex AI Agent Runtime
# Note: agents-cli 1.0.0 supports `deploy agent-engine`
cd ~/agents/github-agent
uvx --from google-agents-cli==1.0.0 agents-cli deploy agent-engine \
  --project "${PROJECT_ID}" \
  --region "${LOCATION}" \
  --display-name "github-agent" \
  --env-vars "GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY=true,OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true,MODEL=gemini-2.5-flash,GITHUB_PAT=${GITHUB_PAT:-ghp_placeholder_token}"
cd ~
```

---

## Task 2: Instrument Agents for Tracing & Emit Traces

### 2.1 Verify OpenTelemetry Dependencies & Exporters

- **Dependency** (`~/agents/salesforce-agent/pyproject.toml` and `~/agents/github-agent/pyproject.toml`):
  ```toml
  "google-adk[gcp,otel-gcp]>=1.14.0,<2.0.0"
  ```
- **Cloud Run Exporter** (`~/agents/salesforce-agent/app/app_utils/telemetry.py`):
  `setup_telemetry()` calls `get_gcp_exporters(enable_cloud_tracing=True, ...)` and registers the span processor via `maybe_set_otel_providers()`.
- **Agent Runtime Exporter** (`~/agents/github-agent/app/app_utils/telemetry.py`):
  Agent Runtime sets `GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY=true` to export spans automatically.

### 2.2 Grant `roles/telemetry.tracesWriter` to the Agent Service Account

Determine the service account used by `salesforce-agent` and grant it `roles/telemetry.tracesWriter`:

```bash
export AGENT_SA=$(gcloud run services describe salesforce-agent \
  --region="${LOCATION}" \
  --format="value(spec.template.spec.serviceAccountName)")

echo "Agent Service Account: ${AGENT_SA}"

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${AGENT_SA}" \
  --role="roles/telemetry.tracesWriter"
```

### 2.3 Query Both Agents to Emit Traces

#### Query `salesforce-agent` on Cloud Run

```bash
export SALESFORCE_AGENT_URL=$(gcloud run services describe salesforce-agent \
  --region="${LOCATION}" \
  --format="value(status.url)")

agents-cli run \
  --url "${SALESFORCE_AGENT_URL}" \
  --mode adk \
  --app-name app \
  "Find documents about onboarding"
```

#### Query `github-agent` on Agent Runtime

```bash
export ENGINE_NAME=$(gcloud alpha ai reasoning-engines list \
  --region="${LOCATION}" \
  --filter="displayName=github-agent" \
  --format="value(name)" | head -n 1)

export ENGINE_ID=$(basename "${ENGINE_NAME}")
export ENGINE_URL="https://${LOCATION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/reasoningEngines/${ENGINE_ID}"

agents-cli run \
  --url "${ENGINE_URL}" \
  --mode adk \
  --app-name app \
  "Find the google/adk-python repository"
```

---

## Task 3: Verify Auto-Discovered Agents

Vertex AI Agent Runtime automatically registers deployed agents in **Agent Registry** and **App Hub**.

```bash
# List agents in Agent Registry
gcloud alpha agent-registry agents list --location="${LOCATION}"

# List MCP servers in Agent Registry
gcloud alpha agent-registry mcp-servers list --location="${LOCATION}"

# List discovered workloads in App Hub
gcloud apphub discovered-workloads list \
  --location="${LOCATION}" \
  --filter="workloadProperties.functionalType.type=AGENT"
```

---

## Task 4: Register the Cloud Run Agent (`salesforce-agent`) in Agent Registry

### 4.1 Provision Discovery Engine Service Agent & Grant `roles/run.invoker`

```bash
gcloud beta services identity create \
  --service=discoveryengine.googleapis.com \
  --project="${PROJECT_ID}"

gcloud run services add-iam-policy-binding salesforce-agent \
  --region="${LOCATION}" \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-discoveryengine.iam.gserviceaccount.com" \
  --role="roles/run.invoker"
```

### 4.2 Fetch the A2A Agent Card (`salesforce_card.json`)

```bash
curl -s \
  -H "Authorization: Bearer $(gcloud auth print-identity-token)" \
  "${SALESFORCE_AGENT_URL}/a2a/app/.well-known/agent-card.json" \
  | jq . > ~/salesforce_card.json

cat ~/salesforce_card.json
```

### 4.3 Register `salesforce-agent` in Agent Registry

```bash
gcloud alpha agent-registry services create salesforce-agent \
  --location="${LOCATION}" \
  --display-name="salesforce-agent" \
  --description="Salesforce document search specialist agent" \
  --agent-protocol=A2A \
  --agent-card-type=json \
  --agent-card-content-file="$HOME/salesforce_card.json"

# Verify both github-agent and salesforce_agent appear
gcloud alpha agent-registry agents list --location="${LOCATION}"
```

---

## Task 5: Register the GitHub MCP Server (`github-mcp`)

### 5.1 Register `github-mcp` Service in Agent Registry

```bash
gcloud alpha agent-registry services create github-mcp \
  --location="${LOCATION}" \
  --display-name="github-mcp" \
  --description="External GitHub Copilot MCP server" \
  --mcp-server-spec-type=no-spec \
  --interfaces="url=https://api.githubcopilot.com/mcp/,protocolBinding=JSONRPC"
```

### 5.2 Verify the Assigned `mcpServerId` Matches `github-agent`

```bash
gcloud alpha agent-registry mcp-servers list --location="${LOCATION}"
```

Expected `mcpServerId` (which matches `custom_metadata={"gcp.mcp.server.destination.id": ...}` in `~/agents/github-agent/app/agent.py`):
```text
urn:mcp:projects-${PROJECT_NUMBER}:projects:${PROJECT_NUMBER}:locations:${LOCATION}:agentregistry:services:github-mcp
```

---

## Task 6: Configure App Hub Application & View Agent Topology

1. In the Google Cloud Console, navigate to **App Hub > Applications** and click **Create application**:
   - **Region**: `us-central1`
   - **Name**: `code-assist-fleet`
   - **Workloads**: Select the `github-agent` reasoning engine workload (`175...`).
2. Navigate to **Trace > Agent Topology** (or **App Topology**):
   - Select application `code-assist-fleet` in `us-central1` to view the multi-agent topology graph and span latency metrics.

---

## Tasks 7–9: Audit & Remediate Over-Privileged Agent Service Accounts

### Task 7 & 8: Analyze Agent Service Account Permissions with Policy Analyzer

```bash
export AGENT_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

# Inspect current IAM roles granted to the agent service account on the project
gcloud projects get-iam-policy "${PROJECT_ID}" \
  --flatten="bindings[].members" \
  --filter="bindings.members:serviceAccount:${AGENT_SA}" \
  --format="table(bindings.role)"

# Run Cloud Asset Inventory Policy Analyzer for the agent service account
gcloud asset analyze-iam-policy \
  --organization="${ORGANIZATION_ID}" \
  --identity="serviceAccount:${AGENT_SA}" \
  --format="table(ACLs.resource, ACLs.role, ACLs.identities[0].name)"
```

### Task 9: Remove Over-Privileged `roles/editor` Binding (Enforce Least Privilege)

If `roles/editor` is bound to the agent service account (e.g., from simulation or misconfiguration):

```bash
# (Simulation step in Task 8 if testing detection)
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${AGENT_SA}" \
  --role="roles/editor"

# Remediation step (Task 9): Remove roles/editor
gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${AGENT_SA}" \
  --role="roles/editor"

# Verify only least-privilege operational roles remain
gcloud projects get-iam-policy "${PROJECT_ID}" \
  --flatten="bindings[].members" \
  --filter="bindings.members:serviceAccount:${AGENT_SA}" \
  --format="table(bindings.role)"
```

Expected remaining roles for `salesforce-agent`:
- `roles/aiplatform.user`
- `roles/telemetry.tracesWriter`
- `roles/logging.logWriter`
- `roles/cloudtrace.agent`

---

## Task 10 (Optional): Agent Platform Threat Detection (`MCP_TOOL_POISONING`)

To test runtime threat detection in **Security Command Center > Findings**:
1. Add a temporary tool in `~/agents/salesforce-agent/app/agent.py` whose docstring contains adversarial prompt-injection instructions (e.g., instructing the model to exfiltrate `os.environ` secrets).
2. Redeploy `salesforce-agent` to Cloud Run and invoke it with `agents-cli run` so the tool declaration is logged in the Vertex AI `generateContent` request.
3. Query SCC findings for `category="MCP_TOOL_POISONING"`:
   ```bash
   gcloud scc findings list "${ORGANIZATION_ID}" \
     --source=- \
     --location=global \
     --filter='category="MCP_TOOL_POISONING" AND state="ACTIVE"' \
     --format="table(finding.category, finding.severity, finding.eventTime, finding.resourceName)"
   ```
4. Remove the poisoned tool from `~/agents/salesforce-agent/app/agent.py` and redeploy.
