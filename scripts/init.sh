# Create the project
gcloud projects create dev-n8n-agent --name="dev-n8n-agent"

# Set it as active
gcloud config set project dev-n8n-agent

# List billing accounts to get your billing ID
gcloud billing accounts list

# Link billing account (replace with your ACCOUNT_ID)
gcloud billing projects link dev-n8n-agent \
  --billing-account=XXXXXXXX-XXXXXXXX-XXXXXXXX

# Verify
gcloud projects describe dev-n8n-agent


# Create the service account
gcloud iam service-accounts create github-actions-sa \
  --display-name="GitHub Actions SA" \
  --project=dev-n8n-agent

# Grant required roles
gcloud projects add-iam-policy-binding dev-n8n-agent \
  --member="serviceAccount:github-actions-sa@dev-n8n-agent.iam.gserviceaccount.com" \
  --role="roles/run.admin"

gcloud projects add-iam-policy-binding dev-n8n-agent \
  --member="serviceAccount:github-actions-sa@dev-n8n-agent.iam.gserviceaccount.com" \
  --role="roles/editor"

gcloud projects add-iam-policy-binding dev-n8n-agent \
  --member="serviceAccount:github-actions-sa@dev-n8n-agent.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountTokenCreator"

# Export JSON key
gcloud iam service-accounts keys create key.json \
  --iam-account=github-actions-sa@dev-n8n-agent.iam.gserviceaccount.com \
  --project=dev-n8n-agent
