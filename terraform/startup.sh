#!/bin/bash
set -e

# ============================================================
# AgentBench VM Startup Script
# Deep Learning VM (Ubuntu 22.04 + CUDA 12.8 + NVIDIA 570)
#
# Flow:
#   1. Install Docker Compose plugin + NVIDIA Container Toolkit
#   2. Clone repository (Secret Manager for private repos)
#   3. Install Python dependencies
#   4. Generate config from instance metadata
#   5. Pre-pull Docker images
#   6. Install & start Systemd services
#      → vLLM (Docker) → Tasks (Controller + Workers) → Assigner
# ============================================================

APP_DIR="/opt/agentbench"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a /var/log/agentbench-startup.log; }

# ============================================================
# 1. Docker Compose plugin
# ============================================================
log "Installing Docker Compose plugin..."
DOCKER_COMPOSE_VERSION="v2.29.1"
mkdir -p /usr/local/lib/docker/cli-plugins
curl -SL "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-x86_64" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# ============================================================
# 2. NVIDIA Container Toolkit (Docker GPU access)
# ============================================================
if ! dpkg -l | grep -q nvidia-container-toolkit; then
  log "Installing NVIDIA Container Toolkit..."
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update && apt-get install -y nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker
fi

# ============================================================
# 3. Clone repository (Self-Clone)
# ============================================================
log "Cloning repository..."
apt-get install -y git

# Secret Manager for private repo (optional)
GITHUB_TOKEN=$(gcloud secrets versions access latest --secret="github-pat" 2>/dev/null || echo "")
if [ -n "$GITHUB_TOKEN" ]; then
  git clone "https://${GITHUB_TOKEN}@github.com/nshiki08/AgentBench_Small_For_LLM2025.git" "$APP_DIR"
else
  git clone "https://github.com/nshiki08/AgentBench_Small_For_LLM2025.git" "$APP_DIR"
fi
cd "$APP_DIR"

# ============================================================
# 4. Python dependencies
# ============================================================
log "Installing Python dependencies..."
pip3 install -r requirements.txt

# ============================================================
# 5. Configuration from instance metadata
# ============================================================
log "Generating configuration..."

VLLM_MODEL=$(curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/vllm-model \
  2>/dev/null || echo "Qwen/Qwen2.5-7B-Instruct")
HF_TOKEN=$(curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/hf-token \
  2>/dev/null || echo "")

# .env (referenced by systemd EnvironmentFile)
cat > "${APP_DIR}/.env" <<EOF
VLLM_MODEL=${VLLM_MODEL}
HUGGING_FACE_HUB_TOKEN=${HF_TOKEN}
EOF

# Substitute model name in agent config
sed -i "s|\${VLLM_MODEL}|${VLLM_MODEL}|g" "${APP_DIR}/configs/agents/api_agents.yaml"

log "Agent config:"
cat "${APP_DIR}/configs/agents/api_agents.yaml"

# ============================================================
# 6. Pre-pull Docker images
# ============================================================
log "Pulling Docker images..."
docker pull mysql:9.5.0 &
docker pull vllm/vllm-openai:v0.13.0 &
wait

# ============================================================
# 7. Install & start Systemd services
# ============================================================
log "Installing systemd services..."

cp "${APP_DIR}/systemd/"*.service /etc/systemd/system/
systemctl daemon-reload

# Start in order: vLLM → Tasks (Controller + Workers) → Assigner
log "Starting agentbench-vllm..."
systemctl enable --now agentbench-vllm

log "Starting agentbench-tasks..."
systemctl enable --now agentbench-tasks

log "Starting agentbench-assigner..."
systemctl enable --now agentbench-assigner

log "=== Startup complete ==="
log "Monitor with:"
log "  journalctl -u agentbench-vllm -f"
log "  journalctl -u agentbench-tasks -f"
log "  journalctl -u agentbench-assigner -f"
