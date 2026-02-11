#!/bin/bash
set -e

# ============================================================
# GCP VM セットアップスクリプト (ローカルから一発実行)
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
#   3. プロビジョニング完了待ち
#   4. SSH 接続情報の表示
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
ZONE="${ZONE:-me-central2-c}"

if [ -z "$PROJECT_ID" ]; then
  echo "ERROR: terraform.tfvars に project_id が設定されていません"
  exit 1
fi

echo "Project: ${PROJECT_ID}"
echo "Zone:    ${ZONE}"
echo ""

# ----------------------------------------------------------
# 2. Terraform apply
# ----------------------------------------------------------
echo "[1/3] Terraform apply..."
cd "${TERRAFORM_DIR}"
terraform init -input=false
terraform apply -auto-approve

INSTANCE_IP=$(terraform output -raw instance_ip 2>/dev/null || echo "")
echo ""
echo "  VM created: ${INSTANCE_IP}"

# ----------------------------------------------------------
# 3. SSH 接続待ち
# ----------------------------------------------------------
echo "[2/3] SSH 接続待ち..."
for i in $(seq 1 30); do
  if gcloud compute ssh agentbench-eval \
    --zone "${ZONE}" --project "${PROJECT_ID}" \
    --command "echo ok" --quiet 2>/dev/null; then
    echo "  SSH ready"
    break
  fi
  if [ "$i" = "30" ]; then
    echo "  WARNING: SSH 接続タイムアウト。VM は作成されましたが SSH 接続を確認できません。"
    echo "  手動で接続してください:"
    echo "    gcloud compute ssh agentbench-eval --zone ${ZONE} --project ${PROJECT_ID}"
    exit 1
  fi
  echo "  Waiting... (${i}/30)"
  sleep 10
done

# ----------------------------------------------------------
# 4. プロビジョニング完了待ち
# ----------------------------------------------------------
echo "[3/3] プロビジョニング完了待ち..."
echo "  (初回はDocker image pull等で10〜15分程度かかります)"
for i in $(seq 1 90); do
  RESULT=$(gcloud compute ssh agentbench-eval \
    --zone "${ZONE}" --project "${PROJECT_ID}" \
    --command "test -f /opt/agentbench/.provisioned && echo 'done' || echo 'waiting'" \
    --quiet 2>/dev/null || echo "waiting")
  if [ "$RESULT" = "done" ]; then
    echo "  プロビジョニング完了!"
    break
  fi
  if [ "$i" = "90" ]; then
    echo "  WARNING: プロビジョニングがタイムアウトしました。"
    echo "  SSH で接続してログを確認してください:"
    echo "    gcloud compute ssh agentbench-eval --zone ${ZONE} --project ${PROJECT_ID}"
    echo "    sudo journalctl -u google-startup-scripts -f"
    exit 1
  fi
  echo "  Provisioning... (${i}/90)"
  sleep 10
done

# ----------------------------------------------------------
# 完了
# ----------------------------------------------------------
echo ""
echo "=========================================="
echo " VM セットアップ完了!"
echo "=========================================="
echo ""
echo "SSH 接続:"
echo "  gcloud compute ssh agentbench-eval --zone ${ZONE} --project ${PROJECT_ID}"
echo ""
echo "VSCode Remote SSH:"
echo "  Host: ${INSTANCE_IP}"
echo "  User: $(whoami)"
echo ""
echo "評価実行 (SSH 接続後):"
echo "  sudo bash /opt/agentbench/scripts/switch-model.sh Qwen/Qwen2.5-7B-Instruct"
echo ""
echo "結果取得 (ローカル):"
echo "  gcloud compute scp --recurse agentbench-eval:/opt/agentbench/outputs/ ./outputs/ --zone ${ZONE} --project ${PROJECT_ID}"
echo ""
echo "VM 削除:"
echo "  cd terraform && terraform destroy"
