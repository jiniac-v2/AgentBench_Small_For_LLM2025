# AgentBench v0.3 Small

[AgentBench](https://github.com/THUDM/AgentBench) の小規模版です。以下の2タスクのみを含みます:

- **DBBench** - データベースクエリタスク (80 tasks)
- **ALFWorld** - 家庭内の対話的タスク (134 tasks)

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

| ドキュメント | 内容 |
|---|---|
| [ローカルマシンの環境構築](docs/setup-local.md) | ローカルマシンの前提条件・リポジトリクローン・vLLM 起動 |
| [VM の環境構築](docs/setup-gcp.md) | GCP VM の構築・接続・管理 (Terraform + gcloud) |
| [セットアップスクリプト](docs/setup.md) | ローカル・GCP 共通の環境構築 (setup-vm.sh / setup-systemd.sh) |
| [評価の実行](docs/runbook.md) | 実験ごとに実行する手順 (モデル切替 → サーバー起動 → 評価) |
| [評価リファレンス](docs/evaluation.md) | サービス監視・トラブルシューティング |

## Citation

```
@article{liu2023agentbench,
  title   = {AgentBench: Evaluating LLMs as Agents},
  author  = {Xiao Liu and Hao Yu and Hanchen Zhang and Yifan Xu and Xuanyu Lei and Hanyu Lai and Yu Gu and Hangliang Ding and Kaiwen Men and Kejuan Yang and Shudan Zhang and Xiang Deng and Aohan Zeng and Zhengxiao Du and Chenhui Zhang and Sheng Shen and Tianjun Zhang and Yu Su and Huan Sun and Minlie Huang and Yuxiao Dong and Jie Tang},
  year    = {2023},
  journal = {arXiv preprint arXiv: 2308.03688}
}
```
