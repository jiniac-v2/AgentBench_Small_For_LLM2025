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
│    ├── Controller                 Port: 5020     │
│    ├── ALFWorld Worker            Port: 5021     │
│    ├── DBBench Worker             Port: 5023     │
│    └── Assigner (Evaluation)                     │
├──────────────────────────────────────────────────┤
│  MySQL (Docker, DBBench用)        Port: 動的     │
│    └── mysql:9.5.0                               │
└──────────────────────────────────────────────────┘
```

## ドキュメント

### ローカル (WSL on GPU)

| ドキュメント | 内容 |
|---|---|
| [環境構築](infra/wsl/setup.md) | WSL2 + NVIDIA GPU のセットアップ |
| [評価の実行](infra/wsl/runbook.md) | ローカル評価の手順・モデル切替・トラブルシューティング |

### クラウド (GCP)

| ドキュメント | 内容 |
|---|---|
| [環境構築](infra/gcp/setup.md) | GCP VM の構築・接続・管理 |
| [評価の実行](infra/gcp/runbook.md) | クラウド評価の手順・監視・トラブルシューティング・大規模評価 |

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

CSV に列挙したモデルを連続で評価します。[Prefect](https://www.prefect.io/) UI で進捗監視、Slack 通知に対応。

```bash
source .venv/bin/activate

# CSV を準備 (初回のみ)
cp eval/models.csv.example eval/models.csv
# eval/models.csv を編集: model_path, hf_token, PreCheck 等を記入

# 実行
prefect server start &                  # Prefect UI: http://localhost:4200
python3 eval/runbook.py eval/models.csv
```

詳細: [WSL 版](infra/wsl/runbook.md#複数モデル一括実行) / [GCP 版](infra/gcp/runbook.md#複数モデル一括実行)

## Citation

```
@article{liu2023agentbench,
  title   = {AgentBench: Evaluating LLMs as Agents},
  author  = {Xiao Liu and Hao Yu and Hanchen Zhang and Yifan Xu and Xuanyu Lei and Hanyu Lai and Yu Gu and Hangliang Ding and Kaiwen Men and Kejuan Yang and Shudan Zhang and Xiang Deng and Aohan Zeng and Zhengxiao Du and Chenhui Zhang and Sheng Shen and Tianjun Zhang and Yu Su and Huan Sun and Minlie Huang and Yuxiao Dong and Jie Tang},
  year    = {2023},
  journal = {arXiv preprint arXiv: 2308.03688}
}
```
