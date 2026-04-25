variable "project_id" {
  description = "GCP project ID"
  type        = string
  default     = "dev-n8n-agent"
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "europe-west2"
}

variable "function_name" {
  description = "Cloud Function name"
  type        = string
  default     = "solar-forecast"
}

variable "schedule" {
  description = "Cron schedule for the daily trigger"
  type        = string
  default     = "0 6 * * *"
}

variable "image" {
  description = "My personal Docker image"
  type = string
  default = "issacamara/solar-forecast:latest"

}
variable "timezone" {
  description = "Scheduler timezone"
  type        = string
  default     = "Africa/Bamako"
}

variable "twilio_account_sid" {
  description = "Twilio Account SID"
  type        = string
  sensitive   = true
}

variable "twilio_auth_token" {
  description = "Twilio Auth Token"
  type        = string
  sensitive   = true
}

variable "twilio_whatsapp_from" {
  description = "Twilio WhatsApp sender number"
  type        = string
  default     = "whatsapp:+14155238886"
}

variable "twilio_whatsapp_to" {
  description = "Destination WhatsApp number"
  type        = string
  sensitive   = true
}
