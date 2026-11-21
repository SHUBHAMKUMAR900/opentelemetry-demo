# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

locals {
  labels = {
    app        = "otel-demo"
    managed-by = "terraform"
  }
}

resource "google_container_cluster" "otel" {
  name     = var.cluster_name
  location = var.zone

  network    = "default"
  subnetwork = "default"

  deletion_protection = false

  release_channel {
    channel = "REGULAR"
  }

  ip_allocation_policy {}

  logging_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]

    managed_prometheus {
      enabled = false
    }
  }

  resource_labels = local.labels
}

resource "google_container_node_pool" "primary" {
  name       = "${var.cluster_name}-pool"
  cluster    = google_container_cluster.otel.id
  location   = var.zone
  node_count = var.node_count

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = var.machine_type
    spot            = var.spot
    disk_size_gb    = var.disk_size_gb
    disk_type       = "pd-balanced"
    service_account = var.node_service_account
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    labels          = local.labels
    resource_labels = local.labels
  }
}
