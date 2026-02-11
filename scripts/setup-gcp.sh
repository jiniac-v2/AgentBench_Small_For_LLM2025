#!/bin/bash
set -e

# ============================================================
# GCP VM セットアップスクリプト (ローカルから実行)
#
# Usage:
#   bash scripts/setup-gcp.sh
#
# Prerequisites:
#   - gcloud CLI インストール・認証済み
#   - terraform >= 1.0 インストール済み
#   - terraform/terraform.tfvars 設定済み
#
# このスクリプトは以下を順番に実行します:
#   1. Terraform apply (VM 作成)
#   2. SSH 接続待ち
#   3. 手順を表示 (SSH → setup-vm.sh を手動実行)
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"

echo "=== AgentBench GCP VM Setup ==="

# ----------------------------------------------------------
# 1. terraform.tfvars チェック
# ----------------------------------------------------------
if [ ! -f "${TERRAFORM_DIR}/terraform.tfvars" ]; then
  echo "ERROR: terraform/terraform.tfvars が見つかりません"
  echo ""
  echo "以下を実行してください:"
  echo "  cp terraform/terraform.tfvars.example terraform/terraform.tfvars"
  echo "  vi terraform/terraform.tfvars  # project_id 等を設定"
  exit 1
fi

# terraform.tfvars から project_id と zone を読み取り (macOS 互換)
PROJECT_ID=$(sed -n 's/.*project_id[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${TERRAFORM_DIR}/terraform.tfvars" 2>/dev/null)
ZONE=$(sed -n 's/.*zone[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${TERRAFORM_DIR}/terraform.tfvars" 2>/dev/null)
ZONE="${ZONE:-asia-northeast1-a}"

if [ -z "$PROJECT_ID" ]; then
  echo "ERROR: terraform.tfvars に project_id が設定されていません"
  exit 1
fi

# ssh_user を自動検出
SSH_USER="$(whoami)"

echo "Project:  ${PROJECT_ID}"
echo "Zone:     ${ZONE}"
echo "SSH User: ${SSH_USER}"
echo ""

# ----------------------------------------------------------
# 2. Terraform apply
# ----------------------------------------------------------
echo "[1/2] Terraform apply..."
cd "${TERRAFORM_DIR}"
terraform init -input=false
terraform apply -auto-approve -var="ssh_user=${SSH_USER}"

INSTANCE_IP=$(terraform output -raw instance_ip 2>/dev/null || echo "")
echo ""
echo "  VM created: ${INSTANCE_IP}"

# ----------------------------------------------------------
# 3. 構築完了待ち (SSH + startup script 完了)
# ----------------------------------------------------------
PROVISION_MARKER="/var/log/agentbench-provisioned"
MAX_WAIT=60  # 60 × 10s = 10分

echo "[2/2] 構築完了待ち (最大 $((MAX_WAIT * 10 / 60)) 分)..."
for i in $(seq 1 ${MAX_WAIT}); do
  RESULT=$(gcloud compute ssh agentbench-eval \
    --zone "${ZONE}" --project "${PROJECT_ID}" \
    --command "test -f ${PROVISION_MARKER} && echo READY || echo NOTYET" \
    --quiet 2>/dev/null || echo "SSH_FAIL")

  if [ "$RESULT" = "READY" ]; then
    echo "  構築完了!"
    break
  fi

  if [ "$i" = "${MAX_WAIT}" ]; then
    echo "  WARNING: タイムアウト (10分)"
    echo "  手動で確認してください:"
    echo "    gcloud compute ssh agentbench-eval --zone ${ZONE} --project ${PROJECT_ID}"
    echo "    sudo tail -f /var/log/agentbench-startup.log"
    exit 1
  fi

  if [ "$RESULT" = "SSH_FAIL" ]; then
    echo "  SSH 接続待ち... (${i}/${MAX_WAIT})"
  else
    echo "  startup script 実行中... (${i}/${MAX_WAIT})"
  fi
  sleep 10
done

# ----------------------------------------------------------
# 完了 — 次のステップを表示
# ----------------------------------------------------------
APP_DIR="/home/${SSH_USER}/AgentBench_Small_For_LLM2025"

echo ""
echo "=========================================="
echo " VM 作成完了!"
echo "=========================================="
echo ""
echo "次のステップ:"
echo ""
echo "1. SSH 接続:"
echo "   gcloud compute ssh agentbench-eval --zone ${ZONE} --project ${PROJECT_ID}"
echo ""
echo "2. 環境構築 (VM 上で実行):"
echo "   sudo bash ${APP_DIR}/scripts/setup-vm.sh"
echo ""
echo "3. 評価実行 (VM 上で実行):"
echo "   sudo bash ${APP_DIR}/scripts/switch-model.sh"
echo ""
echo "VSCode Remote SSH:"
echo "   gcloud compute config-ssh"
echo "   → Remote-SSH: Connect to Host → agentbench-eval.${ZONE}.${PROJECT_ID}"
echo ""
