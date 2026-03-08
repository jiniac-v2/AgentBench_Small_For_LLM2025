#!/usr/bin/env python3
"""
Massive Evaluation Runbook (Prefect版)

CSV に列挙された複数モデルを連続的に評価するオーケストレータ。
各ステップは既存のシェルスクリプトをそのまま呼び出す。

Features:
  - Prefect UI でリアルタイム進捗確認 (localhost:4200)
  - Slack Webhook で完了/エラー/タイムアウト通知
  - モデルごとのタイムアウト制御 (デフォルト 2h20m)
  - CSV 自動更新 (スコア・ステータス・所要時間)

Usage:
  # Prefect サーバー起動 (別ターミナル)
  prefect server start

  # 実行
  sudo python3 scripts/massive_eval/runbook.py [models.csv]

  # Prefect UI 確認 (SSH トンネル経由)
  gcloud compute ssh VM_NAME --ssh-flag="-L 4200:localhost:4200"
  # ブラウザで http://localhost:4200

環境変数 (.env):
  SLACK_WEBHOOK_URL  - Slack Incoming Webhook URL (任意)
"""

import csv
import json
import os
import subprocess
import sys
import time
from datetime import timedelta
from pathlib import Path

from prefect import flow, get_run_logger, task
from prefect.states import Cancelled

# ── 定数 ────────────────────────────────────────────

PIPELINE_TIMEOUT_SEC = 8400  # 2h20m per model
SCRIPT_DIR = Path(__file__).resolve().parent
APP_DIR = SCRIPT_DIR.parent.parent

# ── Slack 通知 ──────────────────────────────────────


def _send_slack(webhook_url: str, message: dict) -> None:
    """Slack Incoming Webhook にメッセージを送信する (requests不要版)."""
    import urllib.request

    req = urllib.request.Request(
        webhook_url,
        data=json.dumps(message).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        urllib.request.urlopen(req, timeout=10)
    except Exception as e:
        # 通知失敗はパイプラインを止めない
        print(f"[Slack] WARNING: 送信失敗: {e}")


def notify_slack(
    webhook_url: str | None,
    *,
    title: str,
    status: str,
    fields: dict | None = None,
    color: str = "#36a64f",
) -> None:
    """Slack に構造化メッセージを送信する."""
    if not webhook_url:
        return

    attachment_fields = []
    if fields:
        for k, v in fields.items():
            attachment_fields.append({"title": k, "value": str(v), "short": True})

    message = {
        "attachments": [
            {
                "color": color,
                "title": title,
                "text": status,
                "fields": attachment_fields,
            }
        ]
    }
    _send_slack(webhook_url, message)


# ── ユーティリティ ──────────────────────────────────


def format_duration(seconds: int) -> str:
    """秒数を HH:MM:SS 形式に変換する."""
    h = seconds // 3600
    m = (seconds % 3600) // 60
    s = seconds % 60
    return f"{h:02d}:{m:02d}:{s:02d}"


def get_latest_output() -> str | None:
    """最新の outputs ディレクトリパスを返す."""
    outputs_dir = APP_DIR / "outputs"
    if not outputs_dir.exists():
        return None
    dirs = sorted(outputs_dir.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True)
    for d in dirs:
        if d.is_dir():
            return str(d)
    return None


def extract_scores(output_dir: str | None) -> tuple[str, str, str]:
    """analysis/result.json からスコアを取得する."""
    if not output_dir:
        return ("", "", "")
    score_file = Path(output_dir) / "analysis" / "result.json"
    if not score_file.exists():
        return ("", "", "")
    try:
        with open(score_file) as f:
            data = json.load(f)
        scores = data.get("overall_scores", {})
        for _agent, s in scores.items():
            return (
                str(s.get("overall_score", "")),
                str(s.get("db_bench_score", "")),
                str(s.get("alf_score", "")),
            )
    except Exception:
        pass
    return ("", "", "")


def update_csv_line(csv_path: str, line_num: int, new_line: str) -> None:
    """CSV の指定行を置き換える (1-indexed)."""
    with open(csv_path) as f:
        lines = f.readlines()
    if 0 < line_num <= len(lines):
        lines[line_num - 1] = new_line + "\n"
    with open(csv_path, "w") as f:
        f.writelines(lines)


# ── Prefect タスク ──────────────────────────────────


@task(name="Step1: vLLM 立ち上げ", log_prints=True)
def step1_start_vllm(model_path: str, read_key: str) -> None:
    """vLLM コンテナを起動する."""
    logger = get_run_logger()
    logger.info(f"vLLM 起動: {model_path}")
    result = subprocess.run(
        ["bash", str(SCRIPT_DIR / "step1_start_vllm.sh"), model_path, read_key],
        capture_output=True,
        text=True,
    )
    print(result.stdout)
    if result.returncode != 0:
        print(result.stderr)
        raise RuntimeError(f"vLLM 起動失敗 (exit={result.returncode})")


@task(name="Step2: 評価実行", log_prints=True)
def step2_evaluate() -> None:
    """タスクサーバー起動 + assigner.py 実行."""
    logger = get_run_logger()
    logger.info("評価実行開始")
    result = subprocess.run(
        ["bash", str(SCRIPT_DIR / "step2_evaluate.sh")],
        capture_output=True,
        text=True,
    )
    print(result.stdout)
    if result.returncode != 0:
        print(result.stderr)
        raise RuntimeError(f"評価失敗 (exit={result.returncode})")


@task(name="Step3: 分析", log_prints=True)
def step3_analysis(output_dir: str) -> None:
    """analysis.py を実行する."""
    logger = get_run_logger()
    logger.info(f"分析実行: {output_dir}")
    result = subprocess.run(
        ["bash", str(SCRIPT_DIR / "step3_analysis.sh"), output_dir],
        capture_output=True,
        text=True,
    )
    print(result.stdout)
    if result.returncode != 0:
        print(result.stderr)
        raise RuntimeError(f"分析失敗 (exit={result.returncode})")


@task(name="Step4: 結果整理", log_prints=True)
def step4_organize(omni_account: str, output_dir: str, results_base: str) -> None:
    """結果を整理する."""
    logger = get_run_logger()
    logger.info(f"結果整理: {omni_account}")
    result = subprocess.run(
        [
            "bash",
            str(SCRIPT_DIR / "step4_organize.sh"),
            omni_account,
            output_dir,
            results_base,
        ],
        capture_output=True,
        text=True,
    )
    print(result.stdout)
    if result.returncode != 0:
        print(result.stderr)
        raise RuntimeError(f"結果整理失敗 (exit={result.returncode})")


# ── モデル単位のサブフロー ──────────────────────────


@flow(
    name="model-evaluation",
    log_prints=True,
    timeout_seconds=PIPELINE_TIMEOUT_SEC,
)
def evaluate_model(
    model_path: str,
    read_key: str,
    omni_account: str,
    results_base: str,
) -> tuple[str, str, str]:
    """1モデルの評価パイプライン (Step1〜4)."""
    # Step 1
    step1_start_vllm(model_path, read_key)

    # Step 2
    step2_evaluate()

    # Step 3
    output_dir = get_latest_output()
    if not output_dir:
        raise RuntimeError("出力ディレクトリが見つかりません")
    step3_analysis(output_dir)

    # Step 4
    step4_organize(omni_account, output_dir, results_base)

    # スコア取得
    return extract_scores(output_dir)


# ── メインフロー ────────────────────────────────────


@flow(name="massive-evaluation", log_prints=True)
def massive_eval(csv_file: str | None = None) -> None:
    """CSV に記載された全モデルを順次評価する."""
    logger = get_run_logger()

    csv_path = csv_file or str(SCRIPT_DIR / "models.csv")
    results_base = str(APP_DIR / "massive_eval_results")
    os.makedirs(results_base, exist_ok=True)

    # Slack Webhook URL (.env から取得)
    webhook_url = os.environ.get("SLACK_WEBHOOK_URL")
    if webhook_url:
        logger.info("Slack 通知: 有効")
    else:
        logger.info("Slack 通知: 無効 (SLACK_WEBHOOK_URL 未設定)")

    if not Path(csv_path).exists():
        raise FileNotFoundError(f"CSV file not found: {csv_path}")

    # CSV 読み込み
    with open(csv_path) as f:
        lines = f.readlines()

    reader = csv.reader(lines)
    header = next(reader)  # ヘッダー行

    total_count = 0
    finish_count = 0
    error_count = 0
    skip_count = 0

    notify_slack(
        webhook_url,
        title="Massive Evaluation 開始",
        status=f"CSV: {Path(csv_path).name}",
        color="#439FE0",
    )

    for csv_line_num_0based, row in enumerate(reader):
        csv_line_num = csv_line_num_0based + 2  # 1-indexed, ヘッダー分+1

        if len(row) < 5:
            continue

        omni_account = row[0].strip()
        omni_id = row[1].strip()
        pre_check = row[2].strip()
        model_path = row[3].strip()
        read_key = row[4].strip()
        current_score = row[5].strip() if len(row) > 5 else ""
        valid_status = row[6].strip() if len(row) > 6 else ""

        if not omni_account or not model_path:
            continue

        total_count += 1

        # Pre-check が OK でなければスキップ
        if pre_check != "OK":
            logger.info(f"[skip] {omni_account} (OmniID={omni_id}) -- Pre-check={pre_check}")
            skip_count += 1
            continue

        # 既に Finish ならスキップ
        if valid_status == "Finish":
            logger.info(f"[skip] {omni_account} (OmniID={omni_id}) -- already Finish")
            skip_count += 1
            continue

        logger.info(f"[{total_count}] {omni_account} (OmniID={omni_id}) Model: {model_path}")

        notify_slack(
            webhook_url,
            title=f"モデル評価開始: {omni_account}",
            status=model_path,
            color="#439FE0",
        )

        pipeline_start = time.time()

        try:
            score_val, db_val, alf_val = evaluate_model(
                model_path=model_path,
                read_key=read_key,
                omni_account=omni_account,
                results_base=results_base,
            )

            duration = format_duration(int(time.time() - pipeline_start))

            # CSV 更新: Finish
            new_line = ",".join([
                omni_account, omni_id, pre_check, model_path, read_key,
                current_score, "Finish", duration, score_val, db_val, alf_val,
            ])
            update_csv_line(csv_path, csv_line_num, new_line)

            logger.info(f"[OK] {omni_account}: Score={score_val} DB={db_val} ALF={alf_val} Time={duration}")
            finish_count += 1

            notify_slack(
                webhook_url,
                title=f"モデル評価完了: {omni_account}",
                status="Finish",
                fields={"Score": score_val, "DB": db_val, "ALF": alf_val, "Time": duration},
                color="#36a64f",
            )

        except TimeoutError:
            duration = format_duration(int(time.time() - pipeline_start))
            new_line = ",".join([
                omni_account, omni_id, pre_check, model_path, read_key,
                current_score, "Valid_TimeOut", duration, "", "", "",
            ])
            update_csv_line(csv_path, csv_line_num, new_line)

            logger.warning(f"[TIMEOUT] {omni_account}: Valid_TimeOut ({duration})")
            error_count += 1

            # クリーンアップ
            subprocess.run(["docker", "stop", "agentbench-vllm"], capture_output=True)

            notify_slack(
                webhook_url,
                title=f"タイムアウト: {omni_account}",
                status=f"Valid_TimeOut ({duration})",
                fields={"Model": model_path},
                color="#ff0000",
            )

        except Exception as e:
            duration = format_duration(int(time.time() - pipeline_start))

            # エラー種別の判定
            error_type = "Valid-Error"
            error_msg = str(e)
            if "vLLM" in error_msg:
                error_type = "vLLM-Error"
            elif "分析" in error_msg or "analysis" in error_msg.lower():
                error_type = "Analysis-Error"

            new_line = ",".join([
                omni_account, omni_id, pre_check, model_path, read_key,
                current_score, error_type, duration, "", "", "",
            ])
            update_csv_line(csv_path, csv_line_num, new_line)

            logger.error(f"[FAIL] {omni_account}: {error_type} ({duration}) - {e}")
            error_count += 1

            notify_slack(
                webhook_url,
                title=f"エラー: {omni_account}",
                status=f"{error_type}: {e}",
                fields={"Model": model_path, "Time": duration},
                color="#ff0000",
            )

    # ── サマリー ──
    summary = (
        f"合計: {total_count} / 成功: {finish_count} / "
        f"失敗: {error_count} / スキップ: {skip_count}"
    )
    logger.info(f"Massive Evaluation 完了 - {summary}")

    notify_slack(
        webhook_url,
        title="Massive Evaluation 完了",
        status=summary,
        fields={"CSV": Path(csv_path).name, "Results": results_base},
        color="#36a64f" if error_count == 0 else "#ff9900",
    )


# ── エントリーポイント ──────────────────────────────

if __name__ == "__main__":
    # .env ファイルの読み込み (dotenv なしで簡易実装)
    env_file = APP_DIR / ".env"
    if env_file.exists():
        with open(env_file) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, _, value = line.partition("=")
                    os.environ.setdefault(key.strip(), value.strip())

    csv_arg = sys.argv[1] if len(sys.argv) > 1 else None
    massive_eval(csv_file=csv_arg)
