#!/bin/bash
set -e

# ============================================================
# GCP VM セットアップスクリプト (ローカルから実行)
#
# Usage:
#   bash scripts/infra/setup-gcp.sh
#
# Prerequisites:
#   - gcloud CLI インストール・認証済み
#   - terraform >= 1.0 インストール済み
#   - terraform/terraform.tfvars 設定済み
#
# このスクリプトは以下を実行します:
#   1. Terraform apply (VM 作成 + startup script で clone まで自動実行)
#   2. 次のステップを表示
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
  echo "  vi terraform/terraform.tfvars  # project_id, git_repo 等を設定"
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

# git_repo を自動検出 (tfvars に未設定の場合はローカルの origin から)
GIT_REPO=$(sed -n 's/.*git_repo[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${TERRAFORM_DIR}/terraform.tfvars" 2>/dev/null)
if [ -z "$GIT_REPO" ]; then
  GIT_REPO=$(git -C "${SCRIPT_DIR}" remote get-url origin 2>/dev/null || echo "")
  GIT_REPO=$(echo "$GIT_REPO" | sed 's|git@github.com:|https://github.com/|')
  GIT_REPO="${GIT_REPO%.git}"
fi

echo "Project:  ${PROJECT_ID}"
echo "Zone:     ${ZONE}"
echo "Repo:     ${GIT_REPO}"
echo ""

# ----------------------------------------------------------
# 2. Terraform apply
# ----------------------------------------------------------
echo "Terraform apply..."
cd "${TERRAFORM_DIR}"
terraform init -input=false
terraform apply -auto-approve \
  -var="ssh_user=$(whoami)" \
  -var="git_repo=${GIT_REPO}"

INSTANCE_IP=$(terraform output -raw instance_ip 2>/dev/null || echo "")

# ----------------------------------------------------------
# 完了 — 次のステップを表示
# ----------------------------------------------------------

echo ""
echo "=========================================="
echo " VM 作成完了!"
echo "=========================================="
echo ""
echo "startup script が clone を実行中です。"
echo "数分待ってから SSH してください。"
echo ""
echo "1. SSH 接続:"
echo "   gcloud compute ssh agentbench-eval --zone ${ZONE} --project ${PROJECT_ID}"
echo ""
echo "2. 環境構築 (VM 上で実行 / 初回のみ):"
echo "   sudo bash ~/AgentBench_Small_For_LLM2025/scripts/setup/setup-vm.sh"
echo ""
echo "3. 評価実行 (VM 上で実行):"
echo "   sudo bash ~/AgentBench_Small_For_LLM2025/scripts/eval/switch-model.sh"
echo ""
echo "VSCode Remote SSH:"
echo "   gcloud compute config-ssh"
echo "   → Remote-SSH: Connect to Host → agentbench-eval.${ZONE}.${PROJECT_ID}"
echo ""
