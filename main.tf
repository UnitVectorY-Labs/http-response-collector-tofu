# Enable required APIs for Cloud Run, Eventarc, Pub/Sub, and Firestore
resource "google_project_service" "run" {
  project            = var.project_id
  service            = "run.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "eventarc" {
  project            = var.project_id
  service            = "eventarc.googleapis.com"
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

# Pub/Sub topic to receive messages and forward to Cloud Run services
resource "google_pubsub_topic" "request" {
  project = var.project_id
  name    = "${var.name}-request"
}

# Pub/Sub topic to receive responses and forward to BigQuery
resource "google_pubsub_topic" "response" {
  project = var.project_id
  name    = "${var.name}-response"
}

resource "google_pubsub_topic_iam_member" "response" {
  project = var.project_id
  topic = google_pubsub_topic.response.name
  role = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.cloud_run_sa.email}"
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
        value = google_pubsub_topic.response.name
      }
    }
  }

  depends_on = [
    // TODO
  ]
}

# Service account for Eventarc triggers
resource "google_service_account" "eventarc_sa" {
  project      = var.project_id
  account_id   = "${var.name}-eventarc-sa"
  display_name = "${var.name} Eventarc Service Account"
}

# IAM role to grant invoke permissions to Eventarc service account for Cloud Run services
resource "google_cloud_run_service_iam_member" "invoke_permission" {
  project  = var.project_id
  location = var.region
  service  = google_cloud_run_v2_service.http_response_collector.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.eventarc_sa.email}"
}

# Pub/Sub subscription to forward messages to Cloud Run services
resource "google_pubsub_subscription" "pubsub_subscription" {
  project                 = var.project_id
  name                    = "bqpas-${var.name}-${var.region}"
  topic                   = google_pubsub_topic.request.name
  enable_message_ordering = true

  push_config {
    push_endpoint = "${google_cloud_run_v2_service.http_response_collector.uri}/pubsub/push"

    oidc_token {
      service_account_email = google_service_account.eventarc_sa.email
    }

    attributes = {
      x-goog-version = "v1"
    }
  }
}