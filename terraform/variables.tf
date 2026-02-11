variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  # me-central2 を使いたいが LOCATION_POLICY_VIOLATED で利用不可のため asia-northeast1 をデフォルトにする
  default     = "asia-northeast1"
}

variable "zone" {
  description = "GCP zone"
  type        = string
  # me-central2-c を使いたいが同上
  default     = "asia-northeast1-a"
}

variable "machine_type" {
  description = "GCE instance machine type (g2-standard-8: 8 vCPUs, 32GB RAM, NVIDIA L4)"
  type        = string
  default     = "g2-standard-8"
}

variable "disk_size_gb" {
  description = "Boot disk size in GB (pd-balanced)"
  type        = number
  default     = 200
}

variable "git_repo" {
  description = "Git repository URL (HTTPS) to clone on the VM"
  type        = string
  default     = ""
}

variable "git_branch" {
  description = "Git branch to clone on the VM"
  type        = string
  default     = "main"
}

variable "ssh_user" {
  description = "SSH username (auto-detected by setup-gcp.sh)"
  type        = string
  default     = ""
}
