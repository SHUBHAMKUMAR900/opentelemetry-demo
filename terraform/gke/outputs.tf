# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

output "project_id" {
  value = var.project_id
}

output "cluster_name" {
  value = google_container_cluster.otel.name
}

output "location" {
  value = google_container_cluster.otel.location
}

output "get_credentials_command" {
  value = "gcloud container clusters get-credentials ${google_container_cluster.otel.name} --zone ${google_container_cluster.otel.location} --project ${var.project_id}"
}
