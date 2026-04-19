terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ─────────────────────────────────────────────
# Enable required GCP APIs
# ─────────────────────────────────────────────
resource "google_project_service" "run" {
  service            = "run.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "sqladmin" {
  service            = "sqladmin.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "secretmanager" {
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "iam" {
  service            = "iam.googleapis.com"
  disable_on_destroy = false
}

# ─────────────────────────────────────────────
# Generate secrets randomly
# ─────────────────────────────────────────────
resource "random_password" "db_password" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}?"
  min_upper        = 4
  min_lower        = 4
  min_numeric      = 4
  min_special      = 2
}

resource "random_password" "n8n_encryption_key" {
  length      = 32
  special     = false   # n8n encryption key: alphanumeric only for safety
  min_upper   = 8
  min_lower   = 8
  min_numeric = 8
}

# ─────────────────────────────────────────────
# Service Account for Cloud Run
# ─────────────────────────────────────────────
resource "google_service_account" "n8n_sa" {
  account_id   = "n8n-service-account"
  display_name = "n8n Service Account"
  project      = var.project_id
}

resource "google_project_iam_member" "n8n_sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.n8n_sa.email}"
}

# ─────────────────────────────────────────────
# Secret Manager — DB Password
# ─────────────────────────────────────────────
resource "google_secret_manager_secret" "db_password" {
  secret_id  = "n8n-db-password"
  project    = var.project_id

  replication {
    auto {}
  }

  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret_version" "db_password" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = random_password.db_password.result
}

resource "google_secret_manager_secret_iam_member" "db_password_access" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.db_password.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.n8n_sa.email}"
}

# ─────────────────────────────────────────────
# Secret Manager — n8n Encryption Key
# ─────────────────────────────────────────────
resource "google_secret_manager_secret" "n8n_encryption_key" {
  secret_id  = "n8n-encryption-key"
  project    = var.project_id

  replication {
    auto {}
  }

  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret_version" "n8n_encryption_key" {
  secret      = google_secret_manager_secret.n8n_encryption_key.id
  secret_data = random_password.n8n_encryption_key.result
}

resource "google_secret_manager_secret_iam_member" "n8n_key_access" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.n8n_encryption_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.n8n_sa.email}"
}

# ─────────────────────────────────────────────
# Cloud SQL — PostgreSQL
# ─────────────────────────────────────────────
resource "google_sql_database_instance" "n8n_db" {
  name             = "n8n-db"
  project          = var.project_id
  database_version = "POSTGRES_15"
  region           = var.region

  settings {
    tier              = "db-f1-micro"
    availability_type = "ZONAL"
    disk_size         = 10
    disk_type         = "PD_HDD"

    backup_configuration {
      enabled = false
    }

    ip_configuration {
      ipv4_enabled = false
    }
  }

  deletion_protection = false
  depends_on          = [google_project_service.sqladmin]
}

resource "google_sql_database" "n8n" {
  name     = var.db_name
  instance = google_sql_database_instance.n8n_db.name
  project  = var.project_id
}

resource "google_sql_user" "n8n_user" {
  name     = var.db_user
  instance = google_sql_database_instance.n8n_db.name
  password = random_password.db_password.result   # Same password as stored in Secret Manager
  project  = var.project_id
}

# ─────────────────────────────────────────────
# Cloud Run — n8n
# ─────────────────────────────────────────────
resource "google_cloud_run_v2_service" "n8n" {
  name     = "n8n"
  location = var.region
  project  = var.project_id
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.n8n_sa.email

    scaling {
      min_instance_count = 0
      max_instance_count = 1
    }

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [google_sql_database_instance.n8n_db.connection_name]
      }
    }

    containers {
      image = var.n8n_image

      ports {
        container_port = 5678
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "2Gi"
        }
        cpu_idle          = true
        startup_cpu_boost = true
      }

            env {
        name  = "N8N_PORT"
        value = "5678"
      }

      env {
        name  = "N8N_PROTOCOL"
        value = "https"
      }

      env {
        name  = "DB_TYPE"
        value = "postgresdb"
      }

      env {
        name  = "DB_POSTGRESDB_DATABASE"
        value = var.db_name
      }

      env {
        name  = "DB_POSTGRESDB_USER"
        value = var.db_user
      }

      env {
        name  = "DB_POSTGRESDB_HOST"
        value = "/cloudsql/${google_sql_database_instance.n8n_db.connection_name}"
      }

      env {
        name  = "DB_POSTGRESDB_PORT"
        value = "5432"
      }

      env {
        name  = "GENERIC_TIMEZONE"
        value = "Africa/Bamako"
      }

      env {
        name  = "N8N_METRICS"
        value = "false"
      }

      env {
        name = "DB_POSTGRESDB_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.db_password.secret_id
            version = "latest"
          }
        }
      }

      env {
        name = "N8N_ENCRYPTION_KEY"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.n8n_encryption_key.secret_id
            version = "latest"
          }
        }
      }


      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }
    }
  }

  depends_on = [
    google_project_service.run,
    google_sql_database.n8n,
    google_sql_user.n8n_user,
    google_secret_manager_secret_version.db_password,
    google_secret_manager_secret_version.n8n_encryption_key,
    google_secret_manager_secret_iam_member.db_password_access,
    google_secret_manager_secret_iam_member.n8n_key_access,
    google_project_iam_member.n8n_sql_client
  ]
}

# Allow public access
resource "google_cloud_run_v2_service_iam_member" "public_invoker" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.n8n.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
