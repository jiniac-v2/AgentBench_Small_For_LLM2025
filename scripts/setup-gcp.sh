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
#   1. Terraform apply (VM 作成, ssh_user を自動設定)
#   2. SSH 接続待ち
#   3. プロビジョニング完了待ち (ログ表示)
#   4. 完了メッセージ
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
# 2. Terraform apply (ssh_user を自動渡し)
# ----------------------------------------------------------
echo "[1/3] Terraform apply..."
cd "${TERRAFORM_DIR}"
terraform init -input=false
terraform apply -auto-approve -var="ssh_user=${SSH_USER}"

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
#    journalctl で startup script の全出力をリアルタイム表示
#    "exit status" が出たら完了
# ----------------------------------------------------------
echo "[3/3] プロビジョニング完了待ち..."
echo "  (初回はDocker/pip install等で10〜15分程度かかります)"
echo ""

gcloud compute ssh agentbench-eval \
  --zone "${ZONE}" --project "${PROJECT_ID}" \
  --command '
    # 既に完了済みなら即終了
    if [ -f /var/log/agentbench-provisioned ]; then
      echo "=========================================="
      echo " プロビジョニング完了!"
      echo "=========================================="
      exit 0
    fi

    # journalctl で startup script の出力をリアルタイムに流す
    # "exit status" が出たら完了 (成功: 0, 失敗: 非0)
    echo "--- startup script ログ ---"
    sudo journalctl -u google-startup-scripts -f --no-pager -o cat 2>/dev/null &
    JOURNAL_PID=$!

    # 裏で完了チェック
    for i in $(seq 1 180); do
      sleep 10

      # マーカーファイルで完了判定
      if [ -f /var/log/agentbench-provisioned ]; then
        kill $JOURNAL_PID 2>/dev/null
        echo ""
        echo "=========================================="
        echo " プロビジョニング完了!"
        echo "=========================================="
        exit 0
      fi

      # journal に exit status が出ていれば完了
      if sudo journalctl -u google-startup-scripts --no-pager -o cat 2>/dev/null | grep -q "startup-script exit status"; then
        kill $JOURNAL_PID 2>/dev/null
        EXIT_LINE=$(sudo journalctl -u google-startup-scripts --no-pager -o cat 2>/dev/null | grep "startup-script exit status" | tail -1)
        echo ""
        if echo "$EXIT_LINE" | grep -q "exit status 0"; then
          echo "=========================================="
          echo " プロビジョニング完了!"
          echo "=========================================="
        else
          echo "=========================================="
          echo " ERROR: startup script が失敗しました"
          echo " ${EXIT_LINE}"
          echo "=========================================="
          exit 1
        fi
        exit 0
      fi
    done

    kill $JOURNAL_PID 2>/dev/null
    echo ""
    echo "WARNING: プロビジョニングがタイムアウトしました (30分)。"
    exit 1
  '

if [ $? -ne 0 ]; then
  echo ""
  echo "WARNING: プロビジョニング待ちに失敗しました。"
  echo "SSH で接続してログを確認してください:"
  echo "  gcloud compute ssh agentbench-eval --zone ${ZONE} --project ${PROJECT_ID}"
  exit 1
fi

# ----------------------------------------------------------
# 完了
# ----------------------------------------------------------
APP_DIR="/home/${SSH_USER}/AgentBench_Small_For_LLM2025"
echo ""
echo "=========================================="
echo " セットアップ完了!"
echo "=========================================="
echo ""
echo "SSH 接続:"
echo "  gcloud compute ssh agentbench-eval --zone ${ZONE} --project ${PROJECT_ID}"
echo ""
echo "VSCode Remote SSH:"
echo "  gcloud compute config-ssh"
echo "  → Remote-SSH: Connect to Host → agentbench-eval.${ZONE}.${PROJECT_ID}"
echo ""
echo "評価実行 (SSH 接続後):"
echo "  vi ${APP_DIR}/scripts/switch-model.sh   # モデル名を編集"
echo "  sudo bash ${APP_DIR}/scripts/switch-model.sh"
echo ""
echo "結果取得 (ローカル):"
echo "  gcloud compute scp --recurse agentbench-eval:${APP_DIR}/outputs/ ./outputs/ --zone ${ZONE} --project ${PROJECT_ID}"
echo ""
