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
# このスクリプトは以下を実行します:
#   1. Terraform apply (VM 作成)
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

echo "Project:  ${PROJECT_ID}"
echo "Zone:     ${ZONE}"
echo ""

# ----------------------------------------------------------
# 2. Terraform apply
# ----------------------------------------------------------
echo "[1/2] Terraform apply..."
cd "${TERRAFORM_DIR}"
terraform init -input=false
terraform apply -auto-approve -var="ssh_user=$(whoami)"

INSTANCE_IP=$(terraform output -raw instance_ip 2>/dev/null || echo "")
echo ""
echo "  VM created: ${INSTANCE_IP}"

# ----------------------------------------------------------
# 完了 — 次のステップを表示
# ----------------------------------------------------------

echo ""
echo "=========================================="
echo " VM 作成完了!"
echo "=========================================="
echo ""
echo "次のステップ (5分ほど待ってから):"
echo ""
echo "1. SSH 接続:"
echo "   gcloud compute ssh agentbench-eval --zone ${ZONE} --project ${PROJECT_ID}"
echo ""
echo "2. リポジトリを clone (VM 上で実行):"
echo "   git clone https://github.com/<owner>/<repo>.git"
echo ""
echo "3. 環境構築 (VM 上で実行):"
echo "   sudo bash ~/AgentBench_Small_For_LLM2025/scripts/setup-vm.sh"
echo ""
echo "4. 評価実行 (VM 上で実行):"
echo "   sudo bash ~/AgentBench_Small_For_LLM2025/scripts/switch-model.sh"
echo ""
echo "VSCode Remote SSH:"
echo "   gcloud compute config-ssh"
echo "   → Remote-SSH: Connect to Host → agentbench-eval.${ZONE}.${PROJECT_ID}"
echo ""
