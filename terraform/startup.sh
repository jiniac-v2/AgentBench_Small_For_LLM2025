#!/bin/bash
set -e

# Install NVIDIA GPU drivers (Container-Optimized OS)
cos-extensions install gpu

# Mount the GPU driver to be available for containers
mount --bind /var/lib/nvidia /var/lib/nvidia
mount -o remount,exec /var/lib/nvidia

# Install Docker Compose
DOCKER_COMPOSE_VERSION="v2.29.1"
mkdir -p /usr/local/bin
curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-x86_64" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Clone the repository
WORK_DIR="/home/agentbench"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Pull the repo (adjust URL as needed)
git clone https://github.com/nshiki08/AgentBench_Small_For_LLM2025.git repo
cd repo

# Create .env from instance metadata
VLLM_MODEL=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/vllm-model 2>/dev/null || echo "meta-llama/Llama-3.1-8B-Instruct")
HF_TOKEN=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/hf-token 2>/dev/null || echo "")

cat > .env <<EOF
VLLM_MODEL=${VLLM_MODEL}
HUGGING_FACE_HUB_TOKEN=${HF_TOKEN}
HF_CACHE_DIR=/home/agentbench/.cache/huggingface
EOF

# Pre-pull MySQL image for DBBench
docker pull mysql:9.5.0

# Start services
/usr/local/bin/docker-compose up -d
