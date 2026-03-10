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

# --- 5000 番台のポートを掃除 (lsof が使えない環境にも対応) ---
cleanup_ports() {
  local PIDS=""
  # 方法1: lsof
  PIDS=$(lsof -ti :5000-5010 2>/dev/null || true)
  # 方法2: lsof が空なら fuser で取得
  if [ -z "$PIDS" ]; then
    for p in $(seq 5000 5010); do
      PIDS="$PIDS $(fuser ${p}/tcp 2>/dev/null || true)"
    done
    PIDS=$(echo "$PIDS" | xargs)  # trim
  fi
  # 方法3: それでも空なら /proc/net/tcp から探す (Linux)
  if [ -z "$PIDS" ]; then
    for p in $(seq 5000 5010); do
      HEX=$(printf '%04X' "$p")
      # /proc/net/tcp の local_address 列 (2列目) からポートを探す
      INODES=$(awk -v hex="$HEX" '$2 ~ ":"hex"$" && $4 == "0A" {print $10}' /proc/net/tcp 2>/dev/null || true)
      for inode in $INODES; do
        # inode からプロセスを逆引き
        PID=$(find /proc/[0-9]*/fd -lname "socket:\[$inode\]" 2>/dev/null | head -1 | cut -d'/' -f3 || true)
        [ -n "$PID" ] && PIDS="$PIDS $PID"
      done
    done
    PIDS=$(echo "$PIDS" | xargs)
  fi
  # 方法4: プロセス名ベースで task_controller / task_worker を kill
  if [ -z "$PIDS" ]; then
    PIDS=$(pgrep -f 'src\.server\.task_controller|src\.server\.task_worker|src\.start_task' 2>/dev/null || true)
  fi

  if [ -n "$PIDS" ]; then
    echo "Killing existing task-server processes: $PIDS"
    echo "$PIDS" | xargs kill 2>/dev/null || true
    sleep 1
    # まだ残っていれば SIGKILL
    for pid in $PIDS; do
      if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
      fi
    done
    sleep 0.5
  fi
}
cleanup_ports

exec python3 -m src.start_task -a --config "$CONFIG"
