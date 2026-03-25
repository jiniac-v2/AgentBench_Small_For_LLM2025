#!/usr/bin/env python3
"""
提出物横断分析スクリプト

outputs/ 配下の全提出物の analysis/ ディレクトリを読み込み、
スコアの傾向・苦手テーマ・相関などを分析して eval/analysis_report/ に出力する。

各提出物の analysis/ 配下には以下のファイルが存在する想定:
    ├── agent_validation.csv   # Agent別 Validation 分析
    ├── overall_score.csv      # Overall Score (DB, ALF, 重み, 総合)
    ├── result.json            # 全分析結果 (summary, overall_scores, details)
    ├── result.yaml            # 同上 (YAML形式)
    ├── summary.csv            # Agent×Task のメインメトリック表
    └── task_validation.csv    # Task別 Validation 分析

Usage:
    python3 eval/analyze_submissions.py [outputs_dir]

出力:
    eval/analysis_report/
        ├── summary.txt          # テキストサマリー (ターミナルにも表示)
        ├── scores_all.csv       # 全モデルの全スコア一覧
        ├── db_by_type.csv       # DBBench タイプ別正答率
        ├── alf_by_category.csv  # ALFWorld カテゴリ別成功率
        ├── correlation.csv      # DB vs ALF 相関データ
        └── validation_all.csv   # 全モデルの Validation 情報一覧
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

# analysis/ 配下の想定ファイル名
ANALYSIS_FILES = [
    "agent_validation.csv",
    "overall_score.csv",
    "result.json",
    "result.yaml",
    "summary.csv",
    "task_validation.csv",
]


# ── データ読み込み ──


def find_submission_dirs(outputs_dir: Path) -> list[dict]:
    """outputs/ 配下の提出ディレクトリを検出する.

    analysis/ ディレクトリに必要なファイルが揃っているかチェックする。
    """
    submissions = []
    if not outputs_dir.exists():
        return submissions

    for d in sorted(outputs_dir.iterdir()):
        if not d.is_dir():
            continue
        label = d.name
        analysis_dir = d / "analysis"

        if not analysis_dir.exists():
            continue

        # 各ファイルの存在チェック
        files = {}
        missing = []
        for fname in ANALYSIS_FILES:
            fpath = analysis_dir / fname
            if fpath.exists():
                files[fname] = fpath
            else:
                missing.append(fname)

        # result.json は必須
        if "result.json" not in files:
            continue

        submissions.append({
            "dir": d,
            "label": label,
            "analysis_dir": analysis_dir,
            "files": files,
            "missing": missing,
        })

    return submissions


def load_json(path: Path) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def load_csv_as_dicts(path: Path) -> list[dict]:
    """CSV を辞書のリストとして読み込む."""
    rows = []
    if not path.exists():
        return rows
    for enc in ["utf-8", "utf-8-sig", "cp932"]:
        try:
            with open(path, encoding=enc) as f:
                reader = csv.DictReader(f)
                for row in reader:
                    rows.append(row)
            return rows
        except (UnicodeDecodeError, KeyError):
            continue
    return rows


# ── 提出物ごとの分析データ抽出 ──


def extract_submission_data(sub: dict) -> dict | None:
    """1 提出の analysis/ ファイル群からデータを抽出する."""
    info = {"label": sub["label"], "dir": str(sub["dir"])}
    files = sub["files"]

    # --- result.json からスコア・詳細取得 ---
    result = load_json(files["result.json"])

    # overall_scores からスコア取得
    overall_scores = result.get("overall_scores", {})
    for agent, scores in overall_scores.items():
        info["agent_name"] = agent
        info["overall_score"] = scores.get("overall_score", 0)
        info["db_score"] = scores.get("db_bench_score", 0)
        info["alf_score"] = scores.get("alf_score", 0)
        info["w_db"] = scores.get("w_db", 0)
        info["w_alf"] = scores.get("w_alf", 0)
        break
    else:
        return None

    # details から DB の詳細精度 (custom 部分) を取得
    details = result.get("details", {})
    for agent, tasks in details.items():
        for task_name, task_data in tasks.items():
            overall = task_data.get("overall", {})
            custom = overall.get("custom", {})
            if custom and task_name.lower().startswith("db"):
                info["db_detailed"] = {
                    k: v for k, v in custom.items()
                    if isinstance(v, (int, float)) and "accuracy" in k
                }
            elif custom and task_name.lower().startswith("alf"):
                # ALFWorld のカテゴリ別成功率
                alf_overall = custom.get("overall", {})
                if alf_overall:
                    info["alf_detailed"] = alf_overall

    # --- overall_score.csv から追加情報 (result.json と重複するが検証用) ---
    if "overall_score.csv" in files:
        oa_rows = load_csv_as_dicts(files["overall_score.csv"])
        if oa_rows:
            info["overall_score_csv"] = oa_rows

    # --- summary.csv からタスク別メトリック取得 ---
    if "summary.csv" in files:
        summary_rows = load_csv_as_dicts(files["summary.csv"])
        info["summary_csv"] = summary_rows

    # --- agent_validation.csv から Agent 別 Validation 取得 ---
    if "agent_validation.csv" in files:
        av_rows = load_csv_as_dicts(files["agent_validation.csv"])
        info["agent_validation"] = av_rows

    # --- task_validation.csv から Task 別 Validation 取得 ---
    if "task_validation.csv" in files:
        tv_rows = load_csv_as_dicts(files["task_validation.csv"])
        info["task_validation"] = tv_rows

    # missing ファイルの警告情報
    if sub["missing"]:
        info["missing_files"] = sub["missing"]

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


def parse_validation_row(row: dict) -> dict[str, float]:
    """Validation CSV の1行から、数値カラムを抽出する."""
    result = {}
    for k, v in row.items():
        if k.endswith("\\Validation") or k.endswith("\\Task"):
            continue
        # 最初のカラム (Agent名/Task名) をスキップ
        if v == "--" or v == "":
            continue
        try:
            result[k] = float(v)
        except (ValueError, TypeError):
            pass
    return result


def generate_report(submissions_data: list[dict]) -> str:
    """分析レポートを生成する."""
    lines = []
    lines.append("=" * 70)
    lines.append("  AgentBench 提出物横断分析レポート")
    lines.append(f"  分析対象: {len(submissions_data)} モデル")
    lines.append("=" * 70)
    lines.append("")

    # ── 1. スコア概要 (overall_score.csv ベース) ──
    overall_scores = [s["overall_score"] for s in submissions_data]
    db_scores = [s["db_score"] for s in submissions_data]
    alf_scores = [s["alf_score"] for s in submissions_data]

    stats_oa = compute_statistics(overall_scores)
    stats_db = compute_statistics(db_scores)
    stats_alf = compute_statistics(alf_scores)

    lines.append("1. スコア概要 (overall_score.csv / result.json ベース)")
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

    # ── 4. DBBench タイプ別分析 (result.json の custom ベース) ──
    lines.append("4. DBBench タイプ別正答率 (result.json custom ベース)")
    lines.append("-" * 50)

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

        lines.append("")
        lines.append("  [苦手タイプ (平均正答率が低い順)]")
        type_means = [(k, compute_statistics(v)["mean"]) for k, v in db_type_scores.items()]
        type_means.sort(key=lambda x: x[1])
        for k, m in type_means[:5]:
            lines.append(f"    {k:30s} {m:.4f}")
    lines.append("")

    # ── 5. summary.csv ベースのタスク別メトリック一覧 ──
    lines.append("5. タスク別メトリック (summary.csv ベース)")
    lines.append("-" * 50)

    task_metrics = defaultdict(list)
    for s in submissions_data:
        for row in s.get("summary_csv", []):
            for k, v in row.items():
                if k.endswith("\\Task") or k == "":
                    continue
                # 最初のカラム (Agent名) をスキップ
                first_key = list(row.keys())[0]
                if k == first_key:
                    continue
                try:
                    task_metrics[k].append(float(v))
                except (ValueError, TypeError):
                    pass

    if task_metrics:
        for task_name in sorted(task_metrics.keys()):
            vals = task_metrics[task_name]
            st = compute_statistics(vals)
            lines.append(
                f"  {task_name:30s} 平均={st['mean']:.4f} 標準偏差={st['std']:.4f} "
                f"中央値={st['median']:.4f} (n={st['n']})"
            )
    lines.append("")

    # ── 6. Validation 分析 (agent_validation.csv / task_validation.csv ベース) ──
    lines.append("6. Validation 分析 (agent_validation.csv ベース)")
    lines.append("-" * 50)

    # Agent Validation 集計
    agent_val_totals = defaultdict(list)
    for s in submissions_data:
        for row in s.get("agent_validation", []):
            parsed = parse_validation_row(row)
            for vk, vv in parsed.items():
                agent_val_totals[vk].append(vv)

    if agent_val_totals:
        for vk in sorted(agent_val_totals.keys()):
            vals = agent_val_totals[vk]
            st = compute_statistics(vals)
            lines.append(f"  {vk:30s} 平均={st['mean']:.1f} 標準偏差={st['std']:.1f} 最大={st['max']:.0f}")
    lines.append("")

    lines.append("  Task Validation (task_validation.csv ベース)")
    lines.append("  " + "-" * 48)

    task_val_totals = defaultdict(lambda: defaultdict(list))
    for s in submissions_data:
        for row in s.get("task_validation", []):
            first_key = list(row.keys())[0]
            task_name = row[first_key]
            parsed = parse_validation_row(row)
            for vk, vv in parsed.items():
                task_val_totals[task_name][vk].append(vv)

    if task_val_totals:
        for task_name in sorted(task_val_totals.keys()):
            lines.append(f"  [{task_name}]")
            for vk in sorted(task_val_totals[task_name].keys()):
                vals = task_val_totals[task_name][vk]
                st = compute_statistics(vals)
                lines.append(f"    {vk:30s} 平均={st['mean']:.1f} 最大={st['max']:.0f}")
            lines.append("")
    lines.append("")

    # ── 7. 上位 vs 下位の特徴比較 ──
    lines.append("7. 上位 vs 下位の特徴比較")
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
    lines.append("")

    # ── 8. スコア分布 ──
    lines.append("8. スコア分布 (ヒストグラム)")
    lines.append("-" * 50)

    for name, scores in [("Overall", overall_scores), ("DB_Bench", db_scores), ("ALFWorld", alf_scores)]:
        lines.append(f"  [{name}]")
        if not scores:
            lines.append("    (データなし)")
            lines.append("")
            continue

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
            bins = [0] * 10
            for v in scores:
                b = min(int(v * 10), 9)
                bins[b] += 1
            for i, cnt in enumerate(bins):
                lo = i * 0.1
                hi = (i + 1) * 0.1
                bar = "#" * cnt
                lines.append(f"    {lo:.1f}-{hi:.1f}: {bar} ({cnt})")
        lines.append("")

    # ── 9. 欠損ファイル警告 ──
    missing_subs = [s for s in submissions_data if s.get("missing_files")]
    if missing_subs:
        lines.append("9. 欠損ファイル警告")
        lines.append("-" * 50)
        for s in missing_subs:
            lines.append(f"  {s['label']}: {', '.join(s['missing_files'])}")
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

    # db_by_type.csv - result.json の custom 詳細精度
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

    # alf_by_category.csv - result.json の ALFWorld 詳細
    alf_cats = set()
    for s in submissions_data:
        if "alf_detailed" in s:
            alf_cats.update(s["alf_detailed"].keys())
    alf_cats = sorted(alf_cats)

    if alf_cats:
        with open(report_dir / "alf_by_category.csv", "w", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow(["label", "overall_score"] + [f"{c}" for c in alf_cats])
            for s in sorted(submissions_data, key=lambda x: x["overall_score"], reverse=True):
                row = [s["label"], s["overall_score"]]
                for c in alf_cats:
                    val = s.get("alf_detailed", {}).get(c, "")
                    row.append(val)
                writer.writerow(row)

    # correlation.csv
    with open(report_dir / "correlation.csv", "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["label", "db_score", "alf_score", "overall_score"])
        for s in sorted(submissions_data, key=lambda x: x["overall_score"], reverse=True):
            writer.writerow([s["label"], s["db_score"], s["alf_score"], s["overall_score"]])

    # validation_all.csv - 全モデルの Validation 情報
    all_val_keys = set()
    for s in submissions_data:
        for row in s.get("agent_validation", []):
            parsed = parse_validation_row(row)
            all_val_keys.update(parsed.keys())
    all_val_keys = sorted(all_val_keys)

    if all_val_keys:
        with open(report_dir / "validation_all.csv", "w", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow(["label"] + all_val_keys)
            for s in sorted(submissions_data, key=lambda x: x["overall_score"], reverse=True):
                row = [s["label"]]
                # agent_validation から最初の行を使う (通常 agent は 1 つ)
                vals = {}
                for av_row in s.get("agent_validation", []):
                    vals = parse_validation_row(av_row)
                    break
                for k in all_val_keys:
                    row.append(vals.get(k, ""))
                writer.writerow(row)


# ── メイン ──


def main():
    outputs_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else APP_DIR / "outputs"

    print(f"outputs: {outputs_dir}")
    print()

    # 提出ディレクトリ検出
    submissions = find_submission_dirs(outputs_dir)
    print(f"検出した提出ディレクトリ: {len(submissions)}")

    if not submissions:
        print("ERROR: outputs/ に analysis/ 付きの提出データが見つかりません。")
        print("採点 (src/analysis.py) 実行後に再度実行してください。")
        sys.exit(1)

    # 各提出の analysis ファイル状況を表示
    for sub in submissions:
        status = "OK" if not sub["missing"] else f"WARN: missing {', '.join(sub['missing'])}"
        print(f"  {sub['label']}: {status}")
    print()

    # 各提出を分析
    results = []
    for sub in submissions:
        data = extract_submission_data(sub)
        if data:
            results.append(data)
        else:
            print(f"  SKIP: {sub['label']} (result.json にスコア情報なし)")

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
    print(f"  validation_all.csv   - 全モデル Validation 情報")


if __name__ == "__main__":
    main()
