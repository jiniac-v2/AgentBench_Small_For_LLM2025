#!/bin/bash
set -e

# ============================================================
# AgentBench タスクサーバー起動スクリプト
#
# Usage:
#   sudo -E bash scripts/eval/task_server_run.sh                              # 全タスク起動
#   sudo -E bash scripts/eval/task_server_run.sh --config configs/start_task_alf.yaml  # ALF だけ
#   sudo -E bash scripts/eval/task_server_run.sh --config configs/start_task_db.yaml   # DB だけ
#   bash scripts/eval/task_server_run.sh stop                                 # サーバー停止
#
# 処理内容:
#   1. 5000 番台のポートを使用中のプロセスを停止 (前回の残骸を掃除)
#   2. vLLM の疎通確認
#   3. Controller + Workers を起動し worker 登録を確認
# ============================================================

PIDFILE="/tmp/agentbench-server.pid"
PORT_RANGE_START=5000
PORT_RANGE_END=5010

# --- ポートクリーンアップ ---
cleanup_ports() {
  echo "Cleaning up ports ${PORT_RANGE_START}-${PORT_RANGE_END}..."
  local found=false
  for port in $(seq "$PORT_RANGE_START" "$PORT_RANGE_END"); do
    pids=$(lsof -ti :"$port" 2>/dev/null || true)
    if [ -n "$pids" ]; then
      found=true
      echo "  Port ${port}: killing PIDs ${pids}"
      echo "$pids" | xargs kill 2>/dev/null || true
    fi
  done
  if $found; then
    sleep 1
    # SIGKILL for stubborn processes
    for port in $(seq "$PORT_RANGE_START" "$PORT_RANGE_END"); do
      pids=$(lsof -ti :"$port" 2>/dev/null || true)
      if [ -n "$pids" ]; then
        echo "  Port ${port}: force killing PIDs ${pids}"
        echo "$pids" | xargs kill -9 2>/dev/null || true
      fi
    done
    sleep 0.5
  fi
  rm -f "$PIDFILE"
  echo "  Ports clean."
}

# --- stop サブコマンド ---
if [ "${1:-}" = "stop" ]; then
  echo "=== Stopping AgentBench Task Server ==="
  cleanup_ports
  echo "Stopped."
  exit 0
fi

# --- 引数パース ---
CONFIG="configs/start_task.yaml"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    *) shift ;;
  esac
done

APP_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$APP_DIR"

echo "=== AgentBench Task Server ==="
echo "Config: ${CONFIG}"

# --- 1. ポートクリーンアップ ---
echo "[1/3] Checking ports..."
cleanup_ports

# --- 2. vLLM 疎通確認 ---
echo "[2/3] Checking vLLM..."
for i in $(seq 1 60); do
  if curl -sf http://localhost:8000/v1/models -o /dev/null 2>/dev/null; then
    MODELS=$(curl -sf http://localhost:8000/v1/models 2>/dev/null || echo "")
    echo "  vLLM ready: $(echo "$MODELS" | python3 -c 'import sys,json; [print(m["id"]) for m in json.load(sys.stdin).get("data",[])]' 2>/dev/null || echo '(unknown)')"
    break
  fi
  if [ "$i" = "60" ]; then
    echo "  ERROR: vLLM not responding on localhost:8000 after 60s"
    exit 1
  fi
  sleep 1
done

# --- alfworld ランタイムデータの確認 ---
if [ -d "data/alfworld" ]; then
  # alfworld のデータディレクトリを検出 (パッケージ内 or ~/.cache/alfworld)
  ALFWORLD_PKG_DATA=$(python3 -c "import os, alfworld; print(os.path.join(os.path.dirname(alfworld.__file__), 'data'))" 2>/dev/null || echo "")
  ALFWORLD_CACHE_DATA="${HOME}/.cache/alfworld"
  # どちらに logic/ があるか判定
  if [ -d "${ALFWORLD_PKG_DATA}/logic" ]; then
    ALFWORLD_DATA_SRC="$ALFWORLD_PKG_DATA"
  elif [ -d "${ALFWORLD_CACHE_DATA}/logic" ]; then
    ALFWORLD_DATA_SRC="$ALFWORLD_CACHE_DATA"
  else
    # どちらにもない → alfworld-download 実行
    echo "  alfworld runtime data not found. Running alfworld-download..."
    alfworld-download 2>&1 || {
      echo "  ERROR: alfworld-download failed. Run manually: alfworld-download"
      exit 1
    }
    # ダウンロード後に再判定
    if [ -d "${ALFWORLD_PKG_DATA}/logic" ]; then
      ALFWORLD_DATA_SRC="$ALFWORLD_PKG_DATA"
    elif [ -d "${ALFWORLD_CACHE_DATA}/logic" ]; then
      ALFWORLD_DATA_SRC="$ALFWORLD_CACHE_DATA"
    else
      echo "  ERROR: alfworld-download succeeded but logic/ dir not found."
      echo "  Checked: ${ALFWORLD_PKG_DATA} and ${ALFWORLD_CACHE_DATA}"
      exit 1
    fi
  fi
  echo "  alfworld data source: ${ALFWORLD_DATA_SRC}"
  # シンボリックリンク作成 (壊れたリンクがあれば上書き)
  for subdir in logic json_2.1.1 detectors; do
    if [ -d "${ALFWORLD_DATA_SRC}/${subdir}" ]; then
      if [ -L "data/alfworld/${subdir}" ] || [ ! -e "data/alfworld/${subdir}" ]; then
        ln -sfn "${ALFWORLD_DATA_SRC}/${subdir}" "data/alfworld/${subdir}"
        echo "  Linked: data/alfworld/${subdir} -> ${ALFWORLD_DATA_SRC}/${subdir}"
      fi
    fi
  done
  # 最終確認
  if [ ! -e "data/alfworld/logic/alfred.pddl" ]; then
    echo "  ERROR: data/alfworld/logic/alfred.pddl not found after setup."
    echo "  Run: alfworld-download && sudo bash scripts/eval/task_server_run.sh"
    exit 1
  fi
fi

# --- 3. Controller + Workers 起動 ---
echo "[3/3] Starting Controller + Workers..."
LOGFILE="logs/task_server_$(date +%Y%m%d_%H%M%S).log"
mkdir -p logs
python3 -m src.start_task -a --config "$CONFIG" </dev/null >"$LOGFILE" 2>&1 &
BG_PID=$!
disown $BG_PID
echo "$BG_PID" > "$PIDFILE"
echo "  Log: $LOGFILE"

# Worker 登録待ち
echo "  Waiting for workers to register..."
CHECK_OK=false
for i in $(seq 1 60); do
  WORKERS=$(curl -sf http://localhost:5000/api/list_workers 2>/dev/null || echo "")
  if [ -n "$WORKERS" ] && [ "$WORKERS" != "" ]; then
    TASKS=$(echo "$WORKERS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(','.join(sorted({w.get('task_name','') for w in data})))
" 2>/dev/null || echo "")
    if [ -n "$TASKS" ]; then
      echo "  Workers registered: ${TASKS}"
      CHECK_OK=true
      break
    fi
  fi
  if [ "$i" = "60" ]; then
    echo "  ERROR: Workers did not register within 120s"
  fi
  sleep 2
done

echo ""
if $CHECK_OK; then
  echo "=== Task server ready (PID: $BG_PID) ==="
  echo ""
  echo "Run evaluation:"
  echo "  python3 -m src.assigner -c configs/assignments/default.yaml"
  echo ""
  echo "Stop server:"
  echo "  bash scripts/eval/task_server_run.sh stop"
  exit 0
else
  echo "=== Startup FAILED — stopping server ==="
  cleanup_ports
  exit 1
fi
