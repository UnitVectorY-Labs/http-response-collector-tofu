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
  topic   = google_pubsub_topic.response.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.cloud_run_sa.email}"
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

# The BigQuery dataset
resource "google_bigquery_dataset" "dataset" {
  project                    = var.project_id
  dataset_id                 = var.name
  friendly_name              = var.name
  description                = "Dataset ${var.name}"
  location                   = var.region
  delete_contents_on_destroy = true
}

# The BigQuery table to store audit logs
resource "google_bigquery_table" "table" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.dataset.dataset_id
  table_id            = "crawl"
  deletion_protection = false

  clustering = ["url", "requestTime"]

  time_partitioning {
    type = "MONTH" # Is this right or should it be "Day"?
  }

  schema = <<EOF
[
  {
    "name": "url",
    "type": "STRING",
    "mode": "NULLABLE",
    "description": "The URL of the request"
  },
  {
    "name": "error",
    "type": "STRING",
    "mode": "NULLABLE",
    "description": "The error message if the request failed"
  },
  {
    "name": "headers",
    "type": "JSON",
    "mode": "NULLABLE",
    "description": "The headers of the response"
  },
  {
    "name": "responseBody",
    "type": "STRING",
    "mode": "NULLABLE",
    "description": "The body of the response if it is not JSON"
  },
  {
    "name": "responseJson",
    "type": "JSON",
    "mode": "NULLABLE",
    "description": "The body of the response if it is JSON"
  },
  {
    "name": "responseTime",
    "type": "INTEGER",
    "mode": "NULLABLE",
    "description": "The time taken to receive the response in milliseconds"
  },
  {
    "name": "requestTime",
    "type": "TIMESTAMP",
    "mode": "NULLABLE",
    "description": "The time the request was made"
  },
  {
    "name": "statusCode",
    "type": "INTEGER",
    "mode": "NULLABLE",
    "description": "The http status code of the response"
  }
]
EOF

}

# Service account for Eventarc triggers
resource "google_service_account" "bigquery_sa" {
  project      = var.project_id
  account_id   = "${var.name}-bigquery-sa"
  display_name = "${var.name} Eventarc Service Account"
}

resource "google_bigquery_dataset_iam_member" "bigquery_editor" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.dataset.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.bigquery_sa.email}"
}

resource "google_pubsub_subscription" "bigquery_subscription" {
  project = var.project_id
  name    = "${var.name}-bigquery-subscription"
  topic   = google_pubsub_topic.response.id

  bigquery_config {
    table                 = "${var.project_id}.${google_bigquery_table.table.dataset_id}.${google_bigquery_table.table.table_id}"
    service_account_email = google_service_account.bigquery_sa.email
    use_table_schema      = true
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.response_dead_letter.id
    max_delivery_attempts = 10
  }

  depends_on = [
    google_service_account.bigquery_sa,
    google_bigquery_dataset_iam_member.bigquery_editor
  ]
}

resource "google_pubsub_topic" "response_dead_letter" {
  project = var.project_id
  name    = "${var.name}-response-dead-letter"
}

resource "google_pubsub_subscription" "response_dead_letter_subscription" {
  project = var.project_id
  name    = "${var.name}-response-dead-letter"
  topic   = google_pubsub_topic.response_dead_letter.id

  # 1 day
  message_retention_duration = "86400s"
  retain_acked_messages      = false

  ack_deadline_seconds = 60

  expiration_policy {
    ttl = "300000.5s"
  }
  retry_policy {
    minimum_backoff = "10s"
  }

  enable_message_ordering = false
}