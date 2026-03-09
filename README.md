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
| [環境構築](docs/local/setup.md) | WSL2 + NVIDIA GPU のセットアップ |
| [評価の実行](docs/local/runbook.md) | ローカル評価の手順・モデル切替・トラブルシューティング |

### クラウド (GCP)

| ドキュメント | 内容 |
|---|---|
| [環境構築](docs/cloud/setup.md) | GCP VM の構築・接続・管理 |
| [評価の実行](docs/cloud/runbook.md) | クラウド評価の手順・監視・トラブルシューティング・大規模評価 |

### 大規模評価 (複数モデル一括)

CSV に列挙した複数モデルを連続で評価するパイプラインです。
[Prefect](https://www.prefect.io/) による GUI 監視と Slack Webhook 通知に対応しています。
詳細は [評価の実行 → 大規模評価](docs/cloud/runbook.md#大規模評価-複数モデル一括実行) を参照してください。

```bash
# Prefect サーバー起動 (別ターミナル)
prefect server start

# 実行
sudo python3 scripts/massive_eval/runbook.py [models.csv]
```

## Citation

```
@article{liu2023agentbench,
  title   = {AgentBench: Evaluating LLMs as Agents},
  author  = {Xiao Liu and Hao Yu and Hanchen Zhang and Yifan Xu and Xuanyu Lei and Hanyu Lai and Yu Gu and Hangliang Ding and Kaiwen Men and Kejuan Yang and Shudan Zhang and Xiang Deng and Aohan Zeng and Zhengxiao Du and Chenhui Zhang and Sheng Shen and Tianjun Zhang and Yu Su and Huan Sun and Minlie Huang and Yuxiao Dong and Jie Tang},
  year    = {2023},
  journal = {arXiv preprint arXiv: 2308.03688}
}
```
