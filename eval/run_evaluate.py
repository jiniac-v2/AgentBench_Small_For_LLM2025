#!/usr/bin/env python3
"""
評価ラッパースクリプト

Assigner を呼ぶ前に以下を行う:
  1. vLLM / タスクサーバーの疎通確認
  2. VLLM_MODEL の自動検出 (.env → vLLM /v1/models)
  3. config 内の ${VLLM_MODEL} を実際のモデル名に置換
  4. 同一プロセス内で Assigner を直接実行

subprocess を使わないので、runbook.py (Prefect) の capture_output=True
環境でもパイプバッファのデッドロックが発生しない。
"""
import argparse
import json
import os
import re
import socket
import sys
import urllib.request


ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


# ── ユーティリティ ──────────────────────────────────────────────

def _info(msg):
    print(f"[run_evaluate] {msg}")


def _error(msg):
    print(f"[run_evaluate] ERROR: {msg}", file=sys.stderr)


def _check_port(host, port, label):
    try:
        with socket.create_connection((host, port), timeout=3):
            _info(f"{label} (port {port}): OK")
            return True
    except (ConnectionRefusedError, OSError) as e:
        _error(f"{label} (port {port}): NG - {e}")
        return False


def _load_env_file(env_path=None):
    if env_path is None:
        env_path = os.path.join(ROOT_DIR, ".env")
    if not os.path.exists(env_path):
        return
    with open(env_path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            key, _, val = line.partition("=")
            key, val = key.strip(), val.strip()
            if key and key not in os.environ:
                os.environ[key] = val


def _auto_detect_vllm_model(vllm_url="http://localhost:8000"):
    try:
        req = urllib.request.Request(f"{vllm_url}/v1/models", method="GET")
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read())
            model_id = data["data"][0]["id"]
            _info(f"vLLM モデル自動検出: {model_id}")
            return model_id
    except Exception as e:
        _error(f"vLLM モデル自動検出に失敗: {e}")
        return ""


def _replace_env_vars(obj):
    """dict/list 内の文字列から ${VAR} を os.environ で置換する (再帰)"""
    if isinstance(obj, str):
        def _repl(m):
            var = m.group(1)
            val = os.environ.get(var)
            if val is None:
                _error(f"環境変数 ${{{var}}} が未定義です")
                return m.group(0)  # そのまま返す
            return val
        return re.sub(r'\$\{([^}]+)\}', _repl, obj)
    elif isinstance(obj, dict):
        return {k: _replace_env_vars(v) for k, v in obj.items()}
    elif isinstance(obj, list):
        return [_replace_env_vars(v) for v in obj]
    return obj


# ── メイン ──────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="AgentBench 評価ラッパー")
    parser.add_argument(
        "--config", "-c", type=str,
        default="configs/assignments/default.yaml",
    )
    parser.add_argument(
        "--auto-retry", "-r", action="store_true", dest="retry",
    )
    args = parser.parse_args()

    # ── 1. 前提条件チェック ──

    _info("前提条件チェック...")

    vllm_ok = _check_port("localhost", 8000, "vLLM サーバー")
    task_ok = _check_port("localhost", 5000, "タスクサーバー")

    if not vllm_ok:
        _error(
            "vLLM サーバー (port 8000) に接続できません\n"
            "  → eval/step1_start_vllm.sh でモデルを起動してください"
        )
        sys.exit(1)

    if not task_ok:
        _error(
            "タスクサーバー (port 5000) に接続できません\n"
            "  → eval/run-task-server.sh を起動してください"
        )
        sys.exit(1)

    # ── 2. VLLM_MODEL の解決 ──

    _load_env_file()

    if not os.environ.get("VLLM_MODEL"):
        _info("VLLM_MODEL 未設定 → vLLM サーバーから自動取得...")
        detected = _auto_detect_vllm_model()
        if detected:
            os.environ["VLLM_MODEL"] = detected
        else:
            _error(
                "VLLM_MODEL が未設定で、vLLM サーバーからも取得できませんでした\n"
                "  export VLLM_MODEL=<model_name> を実行するか .env に設定してください"
            )
            sys.exit(1)

    _info(f"VLLM_MODEL={os.environ['VLLM_MODEL']}")

    # ── 3. config 読み込み → ${VLLM_MODEL} 置換 ──

    sys.path.insert(0, ROOT_DIR)
    os.chdir(ROOT_DIR)

    from src.configs import ConfigLoader
    from src.typings import AssignmentConfig
    from src.assigner import Assigner, std_out_err_redirect_tqdm

    loader = ConfigLoader()
    config_path = os.path.join(ROOT_DIR, args.config)
    config = loader.load_from(config_path)

    # 環境変数の展開
    config = _replace_env_vars(config)

    _info("config 内の環境変数を展開済み")

    # ── 4. Assigner を直接実行 (subprocess を使わない) ──

    _info("AssignmentConfig パース...")
    value = AssignmentConfig.parse_obj(config)
    value = AssignmentConfig.post_validate(value)

    _info("Assigner 開始")
    with std_out_err_redirect_tqdm() as orig_stdout:
        Assigner(value, args.retry).start(tqdm_out=orig_stdout)

    _info("評価完了")


if __name__ == "__main__":
    main()
