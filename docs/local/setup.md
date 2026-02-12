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

## 2. root セットアップ (要 sudo)

```bash
sudo bash scripts/setup/setup-vm-root.sh
```

Docker, NVIDIA Container Toolkit, docker グループ, Python 依存パッケージをインストールします。

完了後、docker グループの反映のため再ログインが必要です:

```bash
exit
# 再ログイン、または:
newgrp docker
```

## 3. セットアップ (sudo 不要)

```bash
bash scripts/setup/setup-vm.sh
```

ALFWorld データのリンク、`.env` / agent config 生成、Docker イメージの pull を行います。

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
