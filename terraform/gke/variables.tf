# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

variable "project_id" {
  description = "GCP project that hosts the cluster"
  type        = string
  default     = "ct-lens"
}

variable "region" {
  description = "Default region for the Google provider"
  type        = string
  default     = "asia-south1"
}

variable "zone" {
  description = "Zone of the cluster. A zonal cluster is covered by the GKE free tier credit, a regional one is not"
  type        = string
  default     = "asia-south1-a"
}

variable "cluster_name" {
  description = "Name of the GKE cluster"
  type        = string
  default     = "otel-demo"
}

variable "node_service_account" {
  description = "Service account the nodes run as. Needs roles/container.defaultNodeServiceAccount and Artifact Registry reader on the otel repository"
  type        = string
  default     = "astronomy-gke-nodes@ct-lens.iam.gserviceaccount.com"
}

variable "machine_type" {
  description = "Machine type of the nodes"
  type        = string
  default     = "e2-standard-4"
}

variable "node_count" {
  description = "Number of nodes in the node pool"
  type        = number
  default     = 1

  validation {
    condition     = var.node_count >= 1 && var.node_count <= 5
    error_message = "node_count must be between 1 and 5."
  }
}

variable "spot" {
  description = "Use Spot VMs for the nodes. Much cheaper, but Google can reclaim a node at any time"
  type        = bool
  default     = false
}

variable "disk_size_gb" {
  description = "Boot disk size of each node in GB"
  type        = number
  default     = 50
}
