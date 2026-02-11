#!/bin/bash
set -e

# ============================================================
# AgentBench VM Startup Script (Idempotent)
# Deep Learning VM (Ubuntu 22.04 + CUDA 12.8 + NVIDIA 570)
#
# Initial boot:
#   1. Install Docker Compose plugin + NVIDIA Container Toolkit
#   2. Clone repository to /home/<user>/AgentBench_Small_For_LLM2025
#   3. Install Python dependencies
#   4. Generate config from instance metadata
#   5. Pre-pull Docker images
#   6. Install & enable Systemd services
#
# Subsequent boots (VM stop→start):
#   - Skip provisioning. Services auto-start via systemd enable.
# ============================================================

PROVISION_MARKER="/var/log/agentbench-provisioned"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a /var/log/agentbench-startup.log; }

# ============================================================
# Skip if already provisioned (stop→start cycle)
# ============================================================
if [ -f "$PROVISION_MARKER" ]; then
  log "Already provisioned. Services auto-start via systemd."
  exit 0
fi

log "=== First-time provisioning START ==="

# ============================================================
# Resolve SSH user → APP_DIR
# ============================================================
SSH_USER=$(curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/ssh-user \
  2>/dev/null || echo "")

if [ -n "$SSH_USER" ]; then
  APP_DIR="/home/${SSH_USER}/AgentBench_Small_For_LLM2025"
  # Ensure user and home directory exist (gcloud SSH creates them later, but we need them now)
  if ! id "$SSH_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$SSH_USER"
    log "Created user: ${SSH_USER}"
  fi
  mkdir -p "/home/${SSH_USER}"
else
  APP_DIR="/opt/agentbench"
  log "WARNING: ssh-user metadata not set. Using ${APP_DIR}"
fi

log "APP_DIR=${APP_DIR}"

# ============================================================
# 1. Docker Engine
# ============================================================
if ! command -v docker &> /dev/null; then
  log "Installing Docker Engine..."
  apt-get update
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
else
  log "Docker already installed."
fi

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
# 3. Clone repository
# ============================================================
log "Cloning repository..."
apt-get install -y git

GIT_BRANCH=$(curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/git-branch \
  2>/dev/null || echo "main")

GITHUB_TOKEN=$(gcloud secrets versions access latest --secret="github-pat" 2>/dev/null || echo "")
if [ -n "$GITHUB_TOKEN" ]; then
  git clone -b "$GIT_BRANCH" "https://${GITHUB_TOKEN}@github.com/nshiki08/AgentBench_Small_For_LLM2025.git" "$APP_DIR"
else
  git clone -b "$GIT_BRANCH" "https://github.com/nshiki08/AgentBench_Small_For_LLM2025.git" "$APP_DIR"
fi

# Set ownership for SSH user
if [ -n "$SSH_USER" ]; then
  chown -R "${SSH_USER}:${SSH_USER}" "$APP_DIR"
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
# 7. Install & enable Systemd services
# ============================================================
log "Installing systemd services..."

# Copy service files, replacing /opt/agentbench placeholder with actual APP_DIR
for f in "${APP_DIR}/systemd/"*.service; do
  sed "s|/opt/agentbench|${APP_DIR}|g" "$f" > "/etc/systemd/system/$(basename "$f")"
done
systemctl daemon-reload

# Enable infrastructure services (auto-start on boot via systemd)
log "Starting agentbench-vllm..."
systemctl enable --now agentbench-vllm

log "Starting agentbench-controller (port 5020)..."
systemctl enable --now agentbench-controller

log "Starting agentbench-worker-dbbench (port 5023)..."
systemctl enable --now agentbench-worker-dbbench

log "Starting agentbench-worker-alfworld (port 5021)..."
systemctl enable --now agentbench-worker-alfworld

# NOTE: Assigner is NOT auto-started. It runs per evaluation via switch-model.sh
log "Assigner service installed (not auto-started)."

# ============================================================
# Mark as provisioned
# ============================================================
touch "$PROVISION_MARKER"

log "=== First-time provisioning COMPLETE ==="
