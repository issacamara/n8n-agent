terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ─────────────────────────────────────────────
# Enable required APIs
# ─────────────────────────────────────────────
resource "google_project_service" "cloudfunctions" {
  service            = "cloudfunctions.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "cloudbuild" {
  service            = "cloudbuild.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "artifactregistry" {
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "run" {
  service            = "run.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "secretmanager" {
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "scheduler" {
  service            = "cloudscheduler.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "iam" {
  service            = "iam.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "storage" {
  service            = "storage.googleapis.com"
  disable_on_destroy = false
}

# ─────────────────────────────────────────────
# GCS bucket to store the function source zip
# ─────────────────────────────────────────────
resource "google_storage_bucket" "source" {
  name                        = "${var.project_id}-function-source"
  project                     = var.project_id
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true

  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.storage]
}

# ─────────────────────────────────────────────
# Zip the app/ source directory
# ─────────────────────────────────────────────
data "archive_file" "source_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../scripts"
  output_path = "${path.module}/tmp/solar-forecast.zip"
}

# ─────────────────────────────────────────────
# Upload zip to GCS — filename includes MD5 so
# Terraform re-uploads on every code change
# ─────────────────────────────────────────────
resource "google_storage_bucket_object" "source_zip" {
  name   = "solar-forecast-${data.archive_file.source_zip.output_md5}.zip"
  bucket = google_storage_bucket.source.name
  source = data.archive_file.source_zip.output_path

  depends_on = [google_storage_bucket.source]
}

# ─────────────────────────────────────────────
# Service Account for the Cloud Function
# ─────────────────────────────────────────────
resource "google_service_account" "function_sa" {
  account_id   = "solar-forecast-fn-sa"
  display_name = "Solar Forecast Function SA"
  project      = var.project_id

  depends_on = [google_project_service.iam]
}

# ─────────────────────────────────────────────
# Secret Manager — Twilio Account SID
# ─────────────────────────────────────────────
resource "google_secret_manager_secret" "twilio_sid" {
  secret_id = "twilio-account-sid"
  project   = var.project_id
  replication {
    auto {}
  }
  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret_version" "twilio_sid" {
  secret      = google_secret_manager_secret.twilio_sid.id
  secret_data = var.twilio_account_sid
  depends_on  = [google_secret_manager_secret.twilio_sid]
}

resource "google_secret_manager_secret_iam_member" "twilio_sid_access" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.twilio_sid.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.function_sa.email}"
  depends_on = [
    google_service_account.function_sa,
    google_secret_manager_secret.twilio_sid
  ]
}

# ─────────────────────────────────────────────
# Secret Manager — Twilio Auth Token
# ─────────────────────────────────────────────
resource "google_secret_manager_secret" "twilio_token" {
  secret_id = "twilio-auth-token"
  project   = var.project_id
  replication {
    auto {}
  }
  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret_version" "twilio_token" {
  secret      = google_secret_manager_secret.twilio_token.id
  secret_data = var.twilio_auth_token
  depends_on  = [google_secret_manager_secret.twilio_token]
}

resource "google_secret_manager_secret_iam_member" "twilio_token_access" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.twilio_token.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.function_sa.email}"
  depends_on = [
    google_service_account.function_sa,
    google_secret_manager_secret.twilio_token
  ]
}

# ─────────────────────────────────────────────
# Secret Manager — Twilio WhatsApp destination
# ─────────────────────────────────────────────
resource "google_secret_manager_secret" "twilio_to" {
  secret_id = "twilio-whatsapp-to"
  project   = var.project_id
  replication {
    auto {}
  }
  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret_version" "twilio_to" {
  secret      = google_secret_manager_secret.twilio_to.id
  secret_data = var.twilio_whatsapp_to
  depends_on  = [google_secret_manager_secret.twilio_to]
}

resource "google_secret_manager_secret_iam_member" "twilio_to_access" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.twilio_to.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.function_sa.email}"
  depends_on = [
    google_service_account.function_sa,
    google_secret_manager_secret.twilio_to
  ]
}

# ─────────────────────────────────────────────
# Cloud Function Gen2
# ─────────────────────────────────────────────
resource "google_cloudfunctions2_function" "solar_forecast" {
  name        = var.function_name
  location    = var.region
  description = "Daily solar production forecast sent via WhatsApp"
  project     = var.project_id

  build_config {
    runtime     = "python312"
    entry_point = "solar_forecast"

    source {
      storage_source {
        bucket = google_storage_bucket.source.name
        object = google_storage_bucket_object.source_zip.name
      }
    }
  }

  service_config {
    service_account_email          = google_service_account.function_sa.email
    max_instance_count             = 1
    min_instance_count             = 0
    available_memory               = "256M"
    timeout_seconds                = 300
    all_traffic_on_latest_revision = true
    ingress_settings               = "ALLOW_ALL"

    environment_variables = {
      TWILIO_WHATSAPP_FROM = var.twilio_whatsapp_from
    }

    secret_environment_variables {
      key        = "TWILIO_ACCOUNT_SID"
      project_id = var.project_id
      secret     = google_secret_manager_secret.twilio_sid.secret_id
      version    = "latest"
    }

    secret_environment_variables {
      key        = "TWILIO_AUTH_TOKEN"
      project_id = var.project_id
      secret     = google_secret_manager_secret.twilio_token.secret_id
      version    = "latest"
    }

    secret_environment_variables {
      key        = "TWILIO_WHATSAPP_TO"
      project_id = var.project_id
      secret     = google_secret_manager_secret.twilio_to.secret_id
      version    = "latest"
    }
  }

  depends_on = [
    google_project_service.cloudfunctions,
    google_project_service.cloudbuild,
    google_project_service.run,
    google_project_service.artifactregistry,
    google_storage_bucket_object.source_zip,
    google_secret_manager_secret_version.twilio_sid,
    google_secret_manager_secret_version.twilio_token,
    google_secret_manager_secret_version.twilio_to,
    google_secret_manager_secret_iam_member.twilio_sid_access,
    google_secret_manager_secret_iam_member.twilio_token_access,
    google_secret_manager_secret_iam_member.twilio_to_access
  ]
}

# ─────────────────────────────────────────────
# Allow Cloud Scheduler to invoke the function
# ─────────────────────────────────────────────
resource "google_service_account" "scheduler_sa" {
  account_id   = "solar-forecast-scheduler-sa"
  display_name = "Solar Forecast Scheduler SA"
  project      = var.project_id

  depends_on = [google_project_service.iam]
}

resource "google_cloud_run_service_iam_member" "scheduler_invoker" {
  project  = var.project_id
  location = var.region
  service  = google_cloudfunctions2_function.solar_forecast.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.scheduler_sa.email}"

  depends_on = [google_cloudfunctions2_function.solar_forecast]
}

# ─────────────────────────────────────────────
# Cloud Scheduler — daily trigger at 6 AM Mali
# ─────────────────────────────────────────────
resource "google_cloud_scheduler_job" "daily_trigger" {
  name        = "solar-forecast-daily"
  region      = var.region
  project     = var.project_id
  description = "Trigger solar forecast Cloud Function every morning"
  schedule    = var.schedule
  time_zone   = var.timezone

  http_target {
    http_method = "POST"
    uri         = google_cloudfunctions2_function.solar_forecast.service_config[0].uri

    headers = {
      "Content-Type" = "application/json"
    }

    body = base64encode(jsonencode({ source = "cloud-scheduler" }))

    oidc_token {
      service_account_email = google_service_account.scheduler_sa.email
      audience              = google_cloudfunctions2_function.solar_forecast.service_config[0].uri
    }
  }

  depends_on = [
    google_project_service.scheduler,
    google_cloud_run_service_iam_member.scheduler_invoker
  ]
}
