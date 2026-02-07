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

resource "google_compute_instance" "agentbench" {
  name         = "agentbench-eval"
  machine_type = var.machine_type
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "projects/cos-cloud/global/images/family/cos-stable"
      size  = var.disk_size_gb
      type  = "pd-ssd"
    }
  }

  guest_accelerator {
    type  = var.gpu_type
    count = var.gpu_count
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
    "cos-metrics-enabled" = "true"
    "user-data" = templatefile("${path.module}/cloud-init.yaml", {
      vllm_model = var.vllm_model
      hf_token   = var.hf_token
    })
  }

  metadata_startup_script = file("${path.module}/startup.sh")

  tags = ["agentbench", "allow-ssh"]

  service_account {
    scopes = ["cloud-platform"]
  }
}

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

output "instance_ip" {
  description = "External IP of the AgentBench VM"
  value       = google_compute_instance.agentbench.network_interface[0].access_config[0].nat_ip
}

output "ssh_command" {
  description = "SSH command to connect to the VM"
  value       = "gcloud compute ssh agentbench-eval --zone ${var.zone} --project ${var.project_id}"
}
