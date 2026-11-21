# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

terraform {
  required_version = ">= 1.17"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.12"
    }
  }

  backend "gcs" {
    bucket = "ct-lens-otel-tfstate"
    prefix = "gke/otel-demo"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
