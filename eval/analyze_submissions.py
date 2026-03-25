#!/usr/bin/env python3
"""
提出物横断分析スクリプト

outputs/ 配下の全提出物を読み込み、スコアの傾向・苦手テーマ・相関などを
分析して eval/analysis_report/ に出力する。

Usage:
    python3 eval/analyze_submissions.py [outputs_dir] [models.csv]

出力:
    eval/analysis_report/
        ├── summary.txt          # テキストサマリー (ターミナルにも表示)
        ├── scores_all.csv       # 全モデルの全スコア一覧
        ├── db_by_type.csv       # DBBench タイプ別正答率
        ├── alf_by_category.csv  # ALFWorld カテゴリ別成功率
        └── correlation.csv      # DB vs ALF 相関データ
"""

import csv
import json
import math
import os
import sys
from collections import defaultdict
from pathlib import Path

APP_DIR = Path(__file__).resolve().parent.parent
REPORT_DIR = APP_DIR / "eval" / "analysis_report"


# ── データ読み込み ──


def find_submission_dirs(outputs_dir: Path) -> list[dict]:
    """outputs/ 配下の提出ディレクトリを検出する."""
    submissions = []
    if not outputs_dir.exists():
        return submissions

    for d in sorted(outputs_dir.iterdir()):
        if not d.is_dir():
            continue
        # {OmniID}_{OmniAccount}_{TIMESTAMP} or just {TIMESTAMP}
        parts = d.name.split("_")
        label = d.name

        # result.json があれば analysis 済み
        result_json = d / "analysis" / "result.json"
        if result_json.exists():
            submissions.append({"dir": d, "label": label, "result_json": result_json})
            continue

        # result.json がなくても overall.json があればデータはある
        has_overall = any((d / "vllm-model").glob("*/overall.json"))
        if has_overall:
            submissions.append({"dir": d, "label": label, "result_json": None})

    return submissions


def load_result_json(path: Path) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def load_overall_json(path: Path) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def load_runs_jsonl(path: Path) -> list[dict]:
    results = []
    if not path.exists():
        return results
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                results.append(json.loads(line))
    return results


def load_dbbench_data(data_file: Path) -> dict:
    """DBBench の問題データを読み込み、index → type のマッピングを作る."""
    idx_to_type = {}
    with open(data_file, encoding="utf-8") as f:
        for i, line in enumerate(f):
            d = json.loads(line)
            t = d.get("type", ["UNKNOWN"])
            if isinstance(t, list):
                t = t[0] if t else "UNKNOWN"
            idx_to_type[i] = t
    return idx_to_type


def load_alfworld_data(data_file: Path) -> dict:
    """ALFWorld の問題データを読み込み、index → category のマッピングを作る."""
    idx_to_cat = {}
    with open(data_file, encoding="utf-8") as f:
        d = json.load(f)
    idx = 0
    for cat, items in d.items():
        for _ in items:
            idx_to_cat[idx] = cat
            idx += 1
    return idx_to_cat


# ── 分析関数 ──


def analyze_submission(sub: dict, db_idx_type: dict, alf_idx_cat: dict) -> dict | None:
    """1 提出のデータを分析する."""
    info = {"label": sub["label"], "dir": str(sub["dir"])}

    # --- result.json からスコア取得 ---
    if sub["result_json"]:
        result = load_result_json(sub["result_json"])
        scores = result.get("overall_scores", {})
        for agent, s in scores.items():
            info["overall_score"] = s.get("overall_score", 0)
            info["db_score"] = s.get("db_bench_score", 0)
            info["alf_score"] = s.get("alf_score", 0)
            break
        else:
            return None

        # details から validation 情報取得
        details = result.get("details", {})
        for agent, tasks in details.items():
            for task_name, task_data in tasks.items():
                overall = task_data.get("overall", {})
                if "validation" in overall:
                    vkey = f"{task_name}_validation"
                    info[vkey] = overall["validation"]
    else:
        return None  # analysis 未実施

    # --- runs.jsonl からタスク別詳細取得 ---
    agent_dir = sub["dir"] / "vllm-model"
    if not agent_dir.exists():
        # agent name が違う場合を探す
        for candidate in sub["dir"].iterdir():
            if candidate.is_dir() and candidate.name != "analysis":
                agent_dir = candidate
                break

    # DBBench 詳細
    db_runs_path = agent_dir / "dbbench-std" / "runs.jsonl"
    db_errors_path = agent_dir / "dbbench-std" / "error.jsonl"
    db_runs = load_runs_jsonl(db_runs_path)
    db_errors = load_runs_jsonl(db_errors_path)

    db_by_type = defaultdict(lambda: {"total": 0, "correct": 0})
    for run in db_runs:
        idx = run.get("index", -1)
        qtype = db_idx_type.get(idx, "UNKNOWN")
        db_by_type[qtype]["total"] += 1
        # 正解判定: output.status == "completed" かつ result.result == 1 (or similar)
        output = run.get("output", {})
        result_data = output.get("result", {}) if output else {}
        if isinstance(result_data, dict) and result_data.get("result") == 1:
            db_by_type[qtype]["correct"] += 1
    for err in db_errors:
        idx = err.get("index", -1)
        qtype = db_idx_type.get(idx, "UNKNOWN")
        db_by_type[qtype]["total"] += 1

    info["db_by_type"] = dict(db_by_type)

    # DBBench overall.json の詳細精度
    db_overall_path = agent_dir / "dbbench-std" / "overall.json"
    if db_overall_path.exists():
        db_overall = load_overall_json(db_overall_path)
        custom = db_overall.get("custom", db_overall)
        info["db_detailed"] = {
            k: v for k, v in custom.items()
            if isinstance(v, (int, float)) and "accuracy" in k
        }

    # ALFWorld 詳細
    alf_runs_path = agent_dir / "alfworld-std" / "runs.jsonl"
    alf_errors_path = agent_dir / "alfworld-std" / "error.jsonl"
    alf_runs = load_runs_jsonl(alf_runs_path)
    alf_errors = load_runs_jsonl(alf_errors_path)

    alf_by_cat = defaultdict(lambda: {"total": 0, "pass": 0})
    for run in alf_runs:
        idx = run.get("index", -1)
        cat = alf_idx_cat.get(idx, "UNKNOWN")
        alf_by_cat[cat]["total"] += 1
        output = run.get("output", {})
        result_data = output.get("result", {}) if output else {}
        if isinstance(result_data, dict) and result_data.get("result") == 1:
            alf_by_cat[cat]["pass"] += 1
    for err in alf_errors:
        idx = err.get("index", -1)
        cat = alf_idx_cat.get(idx, "UNKNOWN")
        alf_by_cat[cat]["total"] += 1

    info["alf_by_cat"] = dict(alf_by_cat)

    # Validation 集計 (完了数, コンテキスト超え, etc.)
    info["validation_summary"] = {}
    for task_name in ["dbbench-std", "alfworld-std"]:
        vkey = f"{task_name}_validation"
        if vkey in info:
            info["validation_summary"][task_name] = info[vkey]

    return info


# ── 集計・レポート ──


def compute_statistics(values: list[float]) -> dict:
    if not values:
        return {"n": 0, "mean": 0, "std": 0, "min": 0, "max": 0, "median": 0}
    n = len(values)
    mean = sum(values) / n
    var = sum((x - mean) ** 2 for x in values) / n if n > 1 else 0
    std = math.sqrt(var)
    s = sorted(values)
    median = s[n // 2] if n % 2 == 1 else (s[n // 2 - 1] + s[n // 2]) / 2
    return {"n": n, "mean": mean, "std": std, "min": s[0], "max": s[-1], "median": median}


def pearson_r(xs: list[float], ys: list[float]) -> float:
    if len(xs) < 3:
        return float("nan")
    n = len(xs)
    mx = sum(xs) / n
    my = sum(ys) / n
    cov = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    sx = math.sqrt(sum((x - mx) ** 2 for x in xs))
    sy = math.sqrt(sum((y - my) ** 2 for y in ys))
    if sx == 0 or sy == 0:
        return float("nan")
    return cov / (sx * sy)


def generate_report(submissions_data: list[dict]) -> str:
    """分析レポートを生成する."""
    lines = []
    lines.append("=" * 70)
    lines.append("  AgentBench 提出物横断分析レポート")
    lines.append(f"  分析対象: {len(submissions_data)} モデル")
    lines.append("=" * 70)
    lines.append("")

    # ── 1. スコア概要 ──
    overall_scores = [s["overall_score"] for s in submissions_data]
    db_scores = [s["db_score"] for s in submissions_data]
    alf_scores = [s["alf_score"] for s in submissions_data]

    stats_oa = compute_statistics(overall_scores)
    stats_db = compute_statistics(db_scores)
    stats_alf = compute_statistics(alf_scores)

    lines.append("1. スコア概要")
    lines.append("-" * 50)
    lines.append(f"  {'':20s} {'平均':>8s} {'標準偏差':>8s} {'中央値':>8s} {'最小':>8s} {'最大':>8s}")
    for name, st in [("Overall Score", stats_oa), ("DB_Bench", stats_db), ("ALFWorld", stats_alf)]:
        lines.append(
            f"  {name:20s} {st['mean']:8.4f} {st['std']:8.4f} "
            f"{st['median']:8.4f} {st['min']:8.4f} {st['max']:8.4f}"
        )
    lines.append("")

    # ── 2. スコアランキング ──
    lines.append("2. スコアランキング (Top 10 / Bottom 10)")
    lines.append("-" * 50)
    ranked = sorted(submissions_data, key=lambda x: x["overall_score"], reverse=True)

    lines.append("  [Top 10]")
    for i, s in enumerate(ranked[:10], 1):
        lines.append(
            f"  {i:3d}. {s['label'][:50]:50s} "
            f"OA={s['overall_score']:.4f} DB={s['db_score']:.4f} ALF={s['alf_score']:.4f}"
        )

    lines.append("")
    lines.append("  [Bottom 10]")
    for i, s in enumerate(ranked[-10:], len(ranked) - 9):
        lines.append(
            f"  {i:3d}. {s['label'][:50]:50s} "
            f"OA={s['overall_score']:.4f} DB={s['db_score']:.4f} ALF={s['alf_score']:.4f}"
        )
    lines.append("")

    # ── 3. DB vs ALF 相関 ──
    r = pearson_r(db_scores, alf_scores)
    lines.append("3. DB_Bench vs ALFWorld 相関")
    lines.append("-" * 50)
    lines.append(f"  Pearson r = {r:.4f}")
    if not math.isnan(r):
        if abs(r) > 0.7:
            lines.append("  → 強い相関: DB と ALF の得意/苦手が連動する傾向")
        elif abs(r) > 0.4:
            lines.append("  → 中程度の相関: ある程度連動するが独立性もある")
        else:
            lines.append("  → 弱い相関: DB と ALF は比較的独立したスキル")
    lines.append("")

    # ── 4. DBBench タイプ別分析 ──
    lines.append("4. DBBench タイプ別正答率 (overall.json ベース)")
    lines.append("-" * 50)

    # overall.json の詳細精度を集計
    db_type_scores = defaultdict(list)
    for s in submissions_data:
        if "db_detailed" in s:
            for k, v in s["db_detailed"].items():
                db_type_scores[k].append(v)

    if db_type_scores:
        for k in sorted(db_type_scores.keys()):
            vals = db_type_scores[k]
            st = compute_statistics(vals)
            lines.append(f"  {k:30s} 平均={st['mean']:.4f} 標準偏差={st['std']:.4f} 中央値={st['median']:.4f}")

        # 苦手タイプ (平均が低い順)
        lines.append("")
        lines.append("  [苦手タイプ (平均正答率が低い順)]")
        type_means = [(k, compute_statistics(v)["mean"]) for k, v in db_type_scores.items()]
        type_means.sort(key=lambda x: x[1])
        for k, m in type_means[:5]:
            lines.append(f"    {k:30s} {m:.4f}")
    lines.append("")

    # ── 5. ALFWorld カテゴリ別分析 ──
    lines.append("5. ALFWorld カテゴリ別成功率")
    lines.append("-" * 50)

    alf_cat_rates = defaultdict(list)
    for s in submissions_data:
        alf_cats = s.get("alf_by_cat", {})
        for cat, data in alf_cats.items():
            if data["total"] > 0:
                alf_cat_rates[cat].append(data["pass"] / data["total"])

    if alf_cat_rates:
        for cat in sorted(alf_cat_rates.keys()):
            vals = alf_cat_rates[cat]
            st = compute_statistics(vals)
            lines.append(
                f"  {cat:30s} 平均={st['mean']:.4f} 標準偏差={st['std']:.4f} "
                f"中央値={st['median']:.4f} (n={st['n']})"
            )

        lines.append("")
        lines.append("  [苦手カテゴリ (平均成功率が低い順)]")
        cat_means = [(c, compute_statistics(v)["mean"]) for c, v in alf_cat_rates.items()]
        cat_means.sort(key=lambda x: x[1])
        for c, m in cat_means:
            lines.append(f"    {c:30s} {m:.4f}")
    lines.append("")

    # ── 6. 上位 vs 下位の特徴比較 ──
    lines.append("6. 上位 vs 下位の特徴比較")
    lines.append("-" * 50)

    n = len(ranked)
    if n >= 6:
        top_n = max(n // 4, 3)
        top_group = ranked[:top_n]
        bottom_group = ranked[-top_n:]

        lines.append(f"  上位 {top_n} モデル vs 下位 {top_n} モデル")
        lines.append("")

        # DB タイプ別比較
        if db_type_scores:
            lines.append("  [DBBench タイプ別: 上位 vs 下位]")
            top_labels = {s["label"] for s in top_group}
            bottom_labels = {s["label"] for s in bottom_group}

            for k in sorted(db_type_scores.keys()):
                top_vals = [s["db_detailed"][k] for s in top_group if "db_detailed" in s and k in s["db_detailed"]]
                bot_vals = [s["db_detailed"][k] for s in bottom_group if "db_detailed" in s and k in s["db_detailed"]]
                if top_vals and bot_vals:
                    top_mean = sum(top_vals) / len(top_vals)
                    bot_mean = sum(bot_vals) / len(bot_vals)
                    diff = top_mean - bot_mean
                    lines.append(
                        f"    {k:30s} 上位={top_mean:.4f} 下位={bot_mean:.4f} 差={diff:+.4f}"
                    )

        lines.append("")

        # ALF カテゴリ別比較
        if alf_cat_rates:
            lines.append("  [ALFWorld カテゴリ別: 上位 vs 下位]")
            for cat in sorted(alf_cat_rates.keys()):
                top_vals = []
                bot_vals = []
                for s in top_group:
                    cd = s.get("alf_by_cat", {}).get(cat, {})
                    if cd.get("total", 0) > 0:
                        top_vals.append(cd["pass"] / cd["total"])
                for s in bottom_group:
                    cd = s.get("alf_by_cat", {}).get(cat, {})
                    if cd.get("total", 0) > 0:
                        bot_vals.append(cd["pass"] / cd["total"])
                if top_vals and bot_vals:
                    top_mean = sum(top_vals) / len(top_vals)
                    bot_mean = sum(bot_vals) / len(bot_vals)
                    diff = top_mean - bot_mean
                    lines.append(
                        f"    {cat:30s} 上位={top_mean:.4f} 下位={bot_mean:.4f} 差={diff:+.4f}"
                    )
    lines.append("")

    # ── 7. Validation 分析 ──
    lines.append("7. Validation 分析 (エラー傾向)")
    lines.append("-" * 50)

    for task_name in ["dbbench-std", "alfworld-std"]:
        val_totals = defaultdict(list)
        for s in submissions_data:
            vdata = s.get("validation_summary", {}).get(task_name, {})
            for vk, vv in vdata.items():
                val_totals[vk].append(vv)

        if val_totals:
            lines.append(f"  [{task_name}]")
            for vk in sorted(val_totals.keys()):
                vals = val_totals[vk]
                st = compute_statistics(vals)
                lines.append(f"    {vk:30s} 平均={st['mean']:.1f} 最大={st['max']:.0f}")
            lines.append("")

    # ── 8. スコア分布 ──
    lines.append("8. スコア分布 (ヒストグラム)")
    lines.append("-" * 50)

    for name, scores in [("Overall", overall_scores), ("DB_Bench", db_scores), ("ALFWorld", alf_scores)]:
        lines.append(f"  [{name}]")
        # 10分割のヒストグラム
        bins = [0] * 10
        for v in scores:
            b = min(int(v * 10), 9)  # 0.0-1.0 の場合
            if name == "Overall":
                b = min(int(v / 1.0), 9)  # overall_score のレンジに応じて調整
            bins[b] += 1

        if name == "Overall":
            max_val = max(scores) if scores else 10
            bin_size = max(max_val / 10, 0.001)
            bins = [0] * 10
            for v in scores:
                b = min(int(v / bin_size), 9)
                bins[b] += 1
            for i, cnt in enumerate(bins):
                lo = bin_size * i
                hi = bin_size * (i + 1)
                bar = "#" * cnt
                lines.append(f"    {lo:6.2f}-{hi:6.2f}: {bar} ({cnt})")
        else:
            for i, cnt in enumerate(bins):
                lo = i * 0.1
                hi = (i + 1) * 0.1
                bar = "#" * cnt
                lines.append(f"    {lo:.1f}-{hi:.1f}: {bar} ({cnt})")
        lines.append("")

    lines.append("=" * 70)
    return "\n".join(lines)


def save_csvs(submissions_data: list[dict], report_dir: Path):
    """CSV ファイルを保存する."""
    report_dir.mkdir(parents=True, exist_ok=True)

    # scores_all.csv
    with open(report_dir / "scores_all.csv", "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["label", "overall_score", "db_score", "alf_score"])
        for s in sorted(submissions_data, key=lambda x: x["overall_score"], reverse=True):
            writer.writerow([s["label"], s["overall_score"], s["db_score"], s["alf_score"]])

    # db_by_type.csv - overall.json の詳細精度
    db_type_keys = set()
    for s in submissions_data:
        if "db_detailed" in s:
            db_type_keys.update(s["db_detailed"].keys())
    db_type_keys = sorted(db_type_keys)

    if db_type_keys:
        with open(report_dir / "db_by_type.csv", "w", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow(["label", "overall_score"] + db_type_keys)
            for s in sorted(submissions_data, key=lambda x: x["overall_score"], reverse=True):
                row = [s["label"], s["overall_score"]]
                for k in db_type_keys:
                    row.append(s.get("db_detailed", {}).get(k, ""))
                writer.writerow(row)

    # alf_by_category.csv
    alf_cats = set()
    for s in submissions_data:
        alf_cats.update(s.get("alf_by_cat", {}).keys())
    alf_cats = sorted(alf_cats)

    if alf_cats:
        with open(report_dir / "alf_by_category.csv", "w", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow(["label", "overall_score"] + [f"{c}_rate" for c in alf_cats])
            for s in sorted(submissions_data, key=lambda x: x["overall_score"], reverse=True):
                row = [s["label"], s["overall_score"]]
                for c in alf_cats:
                    cd = s.get("alf_by_cat", {}).get(c, {})
                    if cd.get("total", 0) > 0:
                        row.append(f"{cd['pass'] / cd['total']:.4f}")
                    else:
                        row.append("")
                writer.writerow(row)

    # correlation.csv
    with open(report_dir / "correlation.csv", "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["label", "db_score", "alf_score", "overall_score"])
        for s in sorted(submissions_data, key=lambda x: x["overall_score"], reverse=True):
            writer.writerow([s["label"], s["db_score"], s["alf_score"], s["overall_score"]])


# ── メイン ──


def load_csv_info(csv_path: Path) -> dict:
    """models.csv から label → モデル情報のマッピングを作る."""
    info = {}
    if not csv_path.exists():
        return info
    # encoding detection
    for enc in ["utf-8", "utf-8-sig", "cp932", "shift_jis"]:
        try:
            with open(csv_path, encoding=enc) as f:
                reader = csv.DictReader(f)
                for row in reader:
                    omni_id = row.get("OmniID", "")
                    account = row.get("OmniAccount", "")
                    if omni_id and account:
                        prefix = f"{omni_id}_{account}_"
                        info[prefix] = row
            return info
        except (UnicodeDecodeError, KeyError):
            continue
    return info


def main():
    outputs_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else APP_DIR / "outputs"
    csv_path = Path(sys.argv[2]) if len(sys.argv) > 2 else APP_DIR / "eval" / "models.csv"

    print(f"outputs: {outputs_dir}")
    print(f"csv: {csv_path}")
    print()

    # 問題データの index → type/category マッピング
    db_data_path = APP_DIR / "data" / "dbbench" / "standard.jsonl"
    alf_data_path = APP_DIR / "data" / "alfworld" / "standard.json"

    db_idx_type = load_dbbench_data(db_data_path) if db_data_path.exists() else {}
    alf_idx_cat = load_alfworld_data(alf_data_path) if alf_data_path.exists() else {}

    print(f"DBBench 問題数: {len(db_idx_type)}")
    print(f"ALFWorld 問題数: {len(alf_idx_cat)}")
    print()

    # 提出ディレクトリ検出
    submissions = find_submission_dirs(outputs_dir)
    print(f"検出した提出ディレクトリ: {len(submissions)}")

    if not submissions:
        print("ERROR: outputs/ に提出データが見つかりません。")
        print("評価実行後に再度実行してください。")
        sys.exit(1)

    # 各提出を分析
    results = []
    for sub in submissions:
        data = analyze_submission(sub, db_idx_type, alf_idx_cat)
        if data:
            results.append(data)
        else:
            print(f"  SKIP: {sub['label']} (analysis 未実施)")

    print(f"分析対象: {len(results)} モデル")
    print()

    if not results:
        print("ERROR: 分析可能なデータがありません。")
        sys.exit(1)

    # レポート生成
    report = generate_report(results)
    print(report)

    # CSV 保存
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    save_csvs(results, REPORT_DIR)

    # テキストレポート保存
    with open(REPORT_DIR / "summary.txt", "w", encoding="utf-8") as f:
        f.write(report)

    print()
    print(f"レポート保存先: {REPORT_DIR}")
    print(f"  summary.txt          - テキストサマリー")
    print(f"  scores_all.csv       - 全モデルスコア一覧")
    print(f"  db_by_type.csv       - DBBench タイプ別精度")
    print(f"  alf_by_category.csv  - ALFWorld カテゴリ別成功率")
    print(f"  correlation.csv      - DB vs ALF 相関データ")


if __name__ == "__main__":
    main()
