terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# ----------------------------------------------------------
# Service Account (VM identity)
# ----------------------------------------------------------
resource "google_service_account" "agentbench" {
  account_id   = "agentbench-vm"
  display_name = "AgentBench VM Service Account"
}

# Secret Manager access (for GitHub PAT, optional)
resource "google_project_iam_member" "secret_access" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.agentbench.email}"
}

# ----------------------------------------------------------
# VM Instance
# ----------------------------------------------------------
resource "google_compute_instance" "agentbench" {
  name         = "agentbench-eval"
  machine_type = var.machine_type
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "projects/deeplearning-platform-release/global/images/family/common-cu128-ubuntu-2204-nvidia-570"
      size  = var.disk_size_gb
      type  = "pd-balanced"
    }
  }

  guest_accelerator {
    type  = "nvidia-l4"
    count = 1
  }

  scheduling {
    on_host_maintenance = "TERMINATE"
    automatic_restart   = true
  }

  network_interface {
    network = "default"
    access_config {}
  }

  metadata = {
    "install-nvidia-driver" = "True"
    "vllm-model"            = var.vllm_model
    "hf-token"              = var.hf_token
  }

  metadata_startup_script = file("${path.module}/startup.sh")

  tags = ["agentbench", "allow-ssh"]

  service_account {
    email  = google_service_account.agentbench.email
    scopes = ["cloud-platform"]
  }
}

# ----------------------------------------------------------
# Firewall
# ----------------------------------------------------------
resource "google_compute_firewall" "allow_ssh" {
  name    = "agentbench-allow-ssh"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-ssh"]
}

# ----------------------------------------------------------
# Outputs
# ----------------------------------------------------------
output "instance_ip" {
  description = "External IP of the AgentBench VM"
  value       = google_compute_instance.agentbench.network_interface[0].access_config[0].nat_ip
}

output "ssh_command" {
  description = "SSH command to connect to the VM"
  value       = "gcloud compute ssh agentbench-eval --zone ${var.zone} --project ${var.project_id}"
}
