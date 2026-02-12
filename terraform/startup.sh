#!/bin/bash
set -e

# ============================================================
# AgentBench VM Startup Script
#
# VM 起動時に root で実行される。リポジトリの clone のみ行う。
# Docker 等のセットアップは SSH 後に setup1.sh / setup2.sh を手動実行する。
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
# 1. リポジトリを clone
# ============================================================
SSH_USER=$(curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/ssh-user \
  2>/dev/null || echo "")
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
log "Next: SSH in and run  sudo bash ~/AgentBench_Small_For_LLM2025/scripts/setup/setup1.sh"
