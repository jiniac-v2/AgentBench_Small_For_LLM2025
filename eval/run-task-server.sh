#!/bin/bash
set -e

# Usage:
#   bash eval/run-task-server.sh          # 全タスク起動
#   bash eval/run-task-server.sh alf      # ALFWorld だけ
#   bash eval/run-task-server.sh db       # DBBench だけ

cd "$(dirname "$0")/.."

# Activate venv
# shellcheck disable=SC1091
[ -f .venv/bin/activate ] && source .venv/bin/activate

case "${1:-}" in
  alf) CONFIG="configs/start_task_alf.yaml" ;;
  db)  CONFIG="configs/start_task_db.yaml"  ;;
  *)   CONFIG="configs/start_task.yaml"     ;;
esac

# --- 5000 番台のポートを掃除 ---
PIDS=$(lsof -ti :5000-5010 2>/dev/null || true)
if [ -n "$PIDS" ]; then
  echo "Killing existing processes on ports 5000-5010: $PIDS"
  echo "$PIDS" | xargs kill 2>/dev/null || true
  sleep 1
  # まだ残っていれば SIGKILL
  PIDS=$(lsof -ti :5000-5010 2>/dev/null || true)
  if [ -n "$PIDS" ]; then
    echo "$PIDS" | xargs kill -9 2>/dev/null || true
    sleep 0.5
  fi
fi

exec python3 -m src.start_task -a --config "$CONFIG"
