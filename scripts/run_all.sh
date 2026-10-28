#!/usr/bin/env bash
# Automated end-to-end execution script for the Agent Observability & Security Lab
set -euo pipefail

export PROJECT_ID=$(gcloud config get-value project)
export PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")
export LOCATION="${LOCATION:-us-central1}"
export ORGANIZATION_ID=$(gcloud projects get-ancestors "${PROJECT_ID}" --format=json | jq -r '.[] | select(.type=="organization") | .id')
export AGENT_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

echo "=== Task 1: Enable APIs ==="
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

echo "=== Task 2: Grant Trace Writer Role ==="
for ROLE in roles/aiplatform.user roles/logging.logWriter roles/cloudtrace.agent roles/telemetry.tracesWriter; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${AGENT_SA}" \
    --role="${ROLE}" \
    --quiet
done

echo "=== Task 4: Grant Discovery Engine Invoker & Register salesforce-agent ==="
gcloud beta services identity create \
  --service=discoveryengine.googleapis.com \
  --project="${PROJECT_ID}"

gcloud run services add-iam-policy-binding salesforce-agent \
  --region="${LOCATION}" \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-discoveryengine.iam.gserviceaccount.com" \
  --role="roles/run.invoker"

export SALESFORCE_AGENT_URL=$(gcloud run services describe salesforce-agent \
  --region="${LOCATION}" \
  --format="value(status.url)")

curl -s \
  -H "Authorization: Bearer $(gcloud auth print-identity-token)" \
  "${SALESFORCE_AGENT_URL}/a2a/app/.well-known/agent-card.json" \
  | jq . > "$HOME/salesforce_card.json"

gcloud alpha agent-registry services create salesforce-agent \
  --location="${LOCATION}" \
  --display-name="salesforce-agent" \
  --description="Salesforce document search specialist agent" \
  --agent-protocol=A2A \
  --agent-card-type=json \
  --agent-card-content-file="$HOME/salesforce_card.json" || true

echo "=== Task 5: Register github-mcp Server ==="
gcloud alpha agent-registry services create github-mcp \
  --location="${LOCATION}" \
  --display-name="github-mcp" \
  --description="External GitHub Copilot MCP server" \
  --mcp-server-spec-type=no-spec \
  --interfaces="url=https://api.githubcopilot.com/mcp/,protocolBinding=JSONRPC" || true

echo "=== Tasks 8 & 9: Policy Analyzer & Least-Privilege Remediation ==="
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${AGENT_SA}" \
  --role="roles/editor" \
  --quiet

gcloud asset analyze-iam-policy \
  --organization="${ORGANIZATION_ID}" \
  --identity="serviceAccount:${AGENT_SA}" \
  --format="table(ACLs.resource, ACLs.role, ACLs.identities[0].name)"

gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${AGENT_SA}" \
  --role="roles/editor" \
  --quiet

echo "=== Done! ==="
