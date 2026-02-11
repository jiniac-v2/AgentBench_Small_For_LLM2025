#!/bin/bash
set -e

# ============================================================
# AgentBench VM Startup Script (Minimal)
#
# VM 起動時に root で実行される。Docker + NVIDIA Container Toolkit
# のインストールのみ行う。アプリケーションのセットアップは SSH 後に
# scripts/setup-vm.sh を手動実行する。
# ============================================================

PROVISION_MARKER="/var/log/agentbench-provisioned"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a /var/log/agentbench-startup.log; }

# Skip if already provisioned (stop→start cycle)
if [ -f "$PROVISION_MARKER" ]; then
  log "Already provisioned. Skipping."
  exit 0
fi

log "=== Startup script START ==="

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
# 2. NVIDIA Container Toolkit
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
# 3. Add SSH user to docker group
# ============================================================
SSH_USER=$(curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/ssh-user \
  2>/dev/null || echo "")

if [ -n "$SSH_USER" ]; then
  if id "$SSH_USER" &>/dev/null; then
    usermod -aG docker "$SSH_USER"
    log "Added ${SSH_USER} to docker group."
  fi
fi

# ============================================================
# 4. リポジトリを clone
# ============================================================
GIT_REPO=$(curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/git-repo \
  2>/dev/null || echo "")
GIT_BRANCH=$(curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/git-branch \
  2>/dev/null || echo "main")

if [ -n "$GIT_REPO" ] && [ -n "$SSH_USER" ]; then
  APP_DIR="/home/${SSH_USER}/AgentBench_Small_For_LLM2025"
  if [ -d "$APP_DIR" ]; then
    log "Repo already exists at ${APP_DIR}. Skipping clone."
  else
    # private リポの場合: Secret Manager から PAT を取得
    PAT=$(gcloud secrets versions access latest --secret=github-pat 2>/dev/null || echo "")
    if [ -n "$PAT" ]; then
      CLONE_URL=$(echo "$GIT_REPO" | sed "s|https://|https://x-access-token:${PAT}@|")
      log "Cloning with GitHub PAT from Secret Manager..."
    else
      CLONE_URL="$GIT_REPO"
      log "Cloning (public repo)..."
    fi
    git clone -b "$GIT_BRANCH" "$CLONE_URL" "$APP_DIR"
    chown -R "${SSH_USER}:${SSH_USER}" "$APP_DIR"
    log "Cloned ${GIT_REPO} (branch: ${GIT_BRANCH}) to ${APP_DIR}"
  fi
else
  log "WARNING: git-repo or ssh-user metadata not set. Skipping clone."
fi

# ============================================================
# Done
# ============================================================
touch "$PROVISION_MARKER"
log "=== Startup script COMPLETE ==="
log "Next: SSH in and run  sudo bash ~/AgentBench_Small_For_LLM2025/scripts/setup-vm.sh"
