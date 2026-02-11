# ローカルマシンの環境構築

## 前提条件

- Python 3.10+
- Docker (GPU 対応)
- NVIDIA GPU + ドライバ

## 1. リポジトリのクローン

```bash
git clone https://github.com/nshiki08/AgentBench_Small_For_LLM2025.git
cd AgentBench_Small_For_LLM2025
```

## 2. vLLM 起動

```bash
# docker compose を使う場合
cp .env.example .env
vi .env  # VLLM_MODEL を設定
docker compose up -d

# または直接実行
docker run --rm --gpus all --ipc=host -p 8000:8000 \
  vllm/vllm-openai:v0.13.0 \
  --model "Qwen/Qwen2.5-7B-Instruct" \
  --max-model-len 8192 \
  --gpu-memory-utilization 0.95
```

## 次のステップ

[セットアップスクリプト](setup.md) に進んでください（systemd は不要です）。
