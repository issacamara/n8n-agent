variable "project_id" {
  description = "GCP Project ID"
  type        = string
  default     = "dev-n8n-agent"
}

variable "region" {
  description = "GCP region for all resources"
  type        = string
  default     = "europe-west2"
}

variable "db_name" {
  description = "PostgreSQL database name"
  type        = string
  default     = "n8n"
}

variable "db_user" {
  description = "PostgreSQL database user"
  type        = string
  default     = "n8n-user"
}

variable "n8n_image" {
  description = "n8n Docker image"
  type        = string
  default     = "docker.io/n8nio/n8n:latest"
}
