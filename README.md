# AgentBench v0.3 Small

[AgentBench](https://github.com/THUDM/AgentBench) の小規模版です。以下の2タスクのみを含みます:

- **DBBench** - データベースクエリタスク (150 tasks)
- **ALFWorld** - 家庭内の対話的タスク (50 tasks)

推論は vLLM (OpenAI互換API) 経由で実行します。

## アーキテクチャ

```
┌──────────────────────────────────────────────────┐
│                   GCE / Local                    │
├──────────────────────────────────────────────────┤
│  vLLM (Docker)                    Port: 8000     │
│    └── vllm/vllm-openai:v0.13.0                 │
├──────────────────────────────────────────────────┤
│  AgentBench (Native Python)                      │
│    ├── Controller                 Port: 5000     │
│    ├── Workers (ALFWorld×5)       Port: 5001-5006│
│    ├── Worker  (DBBench×1)                       │
│    └── Assigner (Evaluation)                     │
├──────────────────────────────────────────────────┤
│  MySQL (Docker, DBBench用)        Port: 動的     │
│    └── mysql:9.5.0                               │
└──────────────────────────────────────────────────┘
```

## ドキュメント

| ドキュメント | 内容 |
|---|---|
| [評価リファレンス](eval/README.md) | CSV スキーマ・パイプライン詳細・デバッグ・トラブルシューティング |

### ローカル (WSL on GPU)

| ドキュメント | 内容 |
|---|---|
| [環境構築](infra/wsl/setup.md) | WSL2 + NVIDIA GPU のセットアップ |
| [評価の実行](infra/wsl/runbook.md) | ローカル評価の手順 |

### クラウド (GCP)

| ドキュメント | 内容 |
|---|---|
| [環境構築](infra/gcp/setup.md) | GCP VM の構築・接続・管理 |
| [評価の実行](infra/gcp/runbook.md) | クラウド評価の手順 |

### 評価の実行

**前提:** 環境構築 ([WSL](infra/wsl/setup.md) or [GCP](infra/gcp/setup.md)) が完了していること

#### 1モデルだけ試す

`.env` にモデルを設定 → vLLM 起動 → 評価 → 結果確認、の流れです。

```bash
source .venv/bin/activate

# vLLM 起動
docker compose down && docker compose up -d

# 評価
bash eval/run-task-server.sh            # 別ターミナルで実行
python3 -m src.assigner -c configs/assignments/default.yaml

# 結果集計
python3 -m src.analysis -o outputs -s analysis
cat analysis/overall_score.csv
```

詳細: [WSL 版](infra/wsl/runbook.md) / [GCP 版](infra/gcp/runbook.md)

#### 複数モデル一括評価

CSV に列挙したモデルを連続で評価します。vLLM のモデル切替・評価・結果集計が自動で繰り返されます。

```bash
source .venv/bin/activate

# CSV を準備 (初回のみ)
cp eval/models.csv.example eval/models.csv
# eval/models.csv を編集: model_path, hf_token, PreCheck 等を記入

# タスクサーバー起動 (別ターミナル)
bash eval/run-task-server.sh

# 評価実行
bash eval/runbook.sh eval/models.csv
```

> **オプション:** [Prefect](https://www.prefect.io/) 版 (`python3 eval/runbook.py`) を使うと Web UI で進捗確認・Slack 通知が可能です。

詳細: [WSL 版](infra/wsl/runbook.md) / [GCP 版](infra/gcp/runbook.md)

## Citation

```
@article{liu2023agentbench,
  title   = {AgentBench: Evaluating LLMs as Agents},
  author  = {Xiao Liu and Hao Yu and Hanchen Zhang and Yifan Xu and Xuanyu Lei and Hanyu Lai and Yu Gu and Hangliang Ding and Kaiwen Men and Kejuan Yang and Shudan Zhang and Xiang Deng and Aohan Zeng and Zhengxiao Du and Chenhui Zhang and Sheng Shen and Tianjun Zhang and Yu Su and Huan Sun and Minlie Huang and Yuxiao Dong and Jie Tang},
  year    = {2023},
  journal = {arXiv preprint arXiv: 2308.03688}
}
```
