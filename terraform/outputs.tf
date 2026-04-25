output "function_url" {
  description = "HTTPS URL of the Cloud Function"
  value       = google_cloudfunctions2_function.solar_forecast.service_config[0].uri
}
