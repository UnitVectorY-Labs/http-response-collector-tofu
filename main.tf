# Enable required APIs for Cloud Run, Eventarc, Pub/Sub, and Firestore
resource "google_project_service" "run" {
  project            = var.project_id
  service            = "run.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "pubsub" {
  project            = var.project_id
  service            = "pubsub.googleapis.com"
  disable_on_destroy = false
}

# Service account for Cloud Run services
resource "google_service_account" "cloud_run_sa" {
  project      = var.project_id
  account_id   = "${var.name}-sa"
  display_name = "${var.name} Cloud Run Service Account"
}

locals {
  final_artifact_registry_project_id = coalesce(var.artifact_registry_project_id, var.project_id)
}

# Deploy Cloud Run services in specified regions
resource "google_cloud_run_v2_service" "http_response_collector" {
  project  = var.project_id
  location = var.region
  name     = var.name
  ingress  = "INGRESS_TRAFFIC_INTERNAL_ONLY"

  deletion_protection = false

  template {
    service_account = google_service_account.cloud_run_sa.email

    containers {
      image = "${var.artifact_registry_host}/${local.final_artifact_registry_project_id}/${var.artifact_registry_name}/unitvectory-labs/http-response-collector:${var.http_response_collector_tag}"

      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.project_id
      }
      env {
        name  = "RESPONSE_PUBSUB"
        value = var.name
      }
    }
  }

  depends_on = [
    // TODO
  ]
}