output "n8n_url" {
  description = "Public URL of the n8n Cloud Run service"
  value       = google_cloud_run_v2_service.n8n.uri
}

output "cloud_sql_connection_name" {
  description = "Cloud SQL connection name"
  value       = google_sql_database_instance.n8n_db.connection_name
}

output "db_password_secret_name" {
  description = "Secret Manager secret name for DB password"
  value       = google_secret_manager_secret.db_password.secret_id
  sensitive   = true
}

output "n8n_encryption_key_secret_name" {
  description = "Secret Manager secret name for n8n encryption key"
  value       = google_secret_manager_secret.n8n_encryption_key.secret_id
  sensitive   = true
}
