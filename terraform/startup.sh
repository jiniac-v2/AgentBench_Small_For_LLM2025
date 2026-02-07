#!/bin/bash
set -e

# Deep Learning VM (common-cu128-ubuntu-2204-nvidia-570) has:
#   - NVIDIA driver 570 + CUDA 12.8 pre-installed
#   - Docker Engine pre-installed
# Only Docker Compose plugin needs to be installed.

# Install Docker Compose plugin
DOCKER_COMPOSE_VERSION="v2.29.1"
mkdir -p /usr/local/lib/docker/cli-plugins
curl -SL "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-x86_64" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# Install NVIDIA Container Toolkit (for Docker GPU access)
if ! dpkg -l | grep -q nvidia-container-toolkit; then
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update && apt-get install -y nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker
fi

# Clone the repository
WORK_DIR="/home/agentbench"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

git clone https://github.com/nshiki08/AgentBench_Small_For_LLM2025.git repo
cd repo

# Create .env from instance metadata
VLLM_MODEL=$(curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/vllm-model \
  2>/dev/null || echo "Qwen/Qwen2.5-7B-Instruct")
HF_TOKEN=$(curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/hf-token \
  2>/dev/null || echo "")

cat > .env <<EOF
VLLM_MODEL=${VLLM_MODEL}
HUGGING_FACE_HUB_TOKEN=${HF_TOKEN}
HF_CACHE_DIR=/home/agentbench/.cache/huggingface
EOF

# Pre-pull MySQL image for DBBench
docker pull mysql:9.5.0

# Start services
docker compose up -d
