# ローカル環境構築

## 前提条件

- Python 3.10+
- Docker (GPU 対応)
- NVIDIA GPU + ドライバ

## 1. リポジトリのクローン

```bash
git clone https://github.com/nshiki08/AgentBench_Small_For_LLM2025.git
cd AgentBench_Small_For_LLM2025
```

## 2. セットアップスクリプト (Part 1 — 要 sudo)

```bash
sudo bash scripts/setup/setup-vm1.sh
```

処理内容:

1. Docker Engine のインストール
2. NVIDIA Container Toolkit のインストール
3. ユーザーを docker グループに追加
4. Python 依存パッケージのインストール

完了後、docker グループの反映のため再ログインが必要です:

```bash
exit
# 再ログイン、または:
newgrp docker
```

## 3. セットアップスクリプト (Part 2 — sudo 不要)

```bash
bash scripts/setup/setup-vm2.sh
```

処理内容:

1. ALFWorld ランタイムデータのダウンロード + リンク (`logic/`, `json_2.1.1/`, `detectors/`)
2. `.env` / agent config の生成
3. Docker イメージの pull (vLLM, MySQL)

> **Note**: systemd (`setup-systemd.sh`) はローカル環境では不要です。

## 3. vLLM 起動

```bash
cp .env.example .env
vi .env  # VLLM_MODEL を設定
docker compose up -d
```

または直接実行:

```bash
docker run --rm --gpus all --ipc=host -p 8000:8000 \
  vllm/vllm-openai:v0.13.0 \
  --model "Qwen/Qwen2.5-7B-Instruct" \
  --max-model-len 8192 \
  --gpu-memory-utilization 0.95
```

## 次のステップ

[ローカル評価の実行](runbook.md) に進んでください。
