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

## 2. セットアップ

```bash
# (1) Docker / NVIDIA / Python 依存 (要 sudo)
sudo bash scripts/setup/setup1.sh

# docker グループ反映のため再ログイン
newgrp docker   # または exit → 再接続

# (2) ALFWorld データ / .env / Docker イメージ pull
bash scripts/setup/setup2.sh
```

> **Note**: `setup_systemd.sh` はローカル環境では不要です。

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
