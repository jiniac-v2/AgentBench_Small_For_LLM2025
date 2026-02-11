variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "me-central2"
}

variable "zone" {
  description = "GCP zone"
  type        = string
  default     = "me-central2-c"
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

variable "vllm_model" {
  description = "HuggingFace model ID or path for vLLM"
  type        = string
  default     = "Qwen/Qwen2.5-7B-Instruct"
}

variable "hf_token" {
  description = "HuggingFace API token (for gated models)"
  type        = string
  default     = ""
  sensitive   = true
}
