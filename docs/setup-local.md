# 環境構築: ローカル

## 前提条件

- Python 3.10+
- Docker (GPU 対応)
- NVIDIA GPU + ドライバ

## 1. リポジトリのクローン・依存関係

```bash
git clone https://github.com/nshiki08/AgentBench_Small_For_LLM2025.git
cd AgentBench_Small_For_LLM2025

python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

Docker が動作していることを確認:

```bash
docker ps
docker pull mysql:9.5.0
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

## 3. 動作確認

```bash
# vLLM ヘルスチェック
curl http://localhost:8000/health

# 推論テスト
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct",
    "messages": [{"role": "user", "content": "Hi"}],
    "max_tokens": 10
  }'
```

環境構築は以上です。評価の実行は [評価実行ガイド](evaluation.md) を参照してください。
