# ローカル環境構築 (WSL on GPU)

Windows + WSL2 + NVIDIA GPU でのセットアップ手順です。

> **Docker Desktop を使う場合**: [WSL2 + GPU 環境構築ガイド (Docker Desktop)](wsl-gpu-setup.md) を参照してください。
> 以下は Docker Engine を直接 WSL 内にインストールするパターンです。

## 前提条件

### Windows 側

- Windows 10 (21H2+) または Windows 11
- **NVIDIA GPU ドライバ** (Game Ready / Studio) — [ダウンロード](https://www.nvidia.com/Download/index.aspx)
  - WSL2 では **Windows 側にドライバを入れるだけ** で OK（WSL 内にドライバは不要）
- WSL2 が有効化済み

### WSL 側

- Ubuntu 22.04 or 24.04 (推奨)
- Python 3.10+

> **Note**: WSL 内に `nvidia-driver-*` パッケージは **インストールしないでください**。Windows 側のドライバが `/usr/lib/wsl/lib/` 経由で自動共有されます。

---

## Step 1: WSL2 の準備

### WSL2 がまだの場合

PowerShell (管理者) で:

```powershell
wsl --install -d Ubuntu-22.04
```

インストール後、再起動してユーザー名・パスワードを設定してください。

### WSL2 が既にある場合

バージョンが 2 であることを確認:

```powershell
wsl -l -v
```

```
  NAME            STATE           VERSION
* Ubuntu-22.04    Running         2
```

VERSION が `1` の場合は変換:

```powershell
wsl --set-version Ubuntu-22.04 2
```

---

## Step 2: GPU の動作確認

WSL 内で以下を実行:

```bash
nvidia-smi
```

GPU の情報が表示されれば OK です。

```
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 570.xx.xx    Driver Version: 570.xx.xx    CUDA Version: 12.x                 |
|   ...
| GPU  Name        ...
|   0  NVIDIA GeForce RTX 4090  ...
+-----------------------------------------------------------------------------------------+
```

表示されない場合:
1. Windows 側で最新の NVIDIA ドライバがインストールされているか確認
2. WSL を再起動: PowerShell で `wsl --shutdown` → WSL を再度開く
3. WSL カーネルを更新: `wsl --update`

---

## Step 3: リポジトリのクローン

```bash
cd ~
git clone https://github.com/nshiki08/AgentBench_Small_For_LLM2025.git
cd AgentBench_Small_For_LLM2025
```

> **private リポの場合**: GitHub PAT を使って clone してください。

---

## Step 4: セットアップスクリプト

| スクリプト | 用途 |
|---|---|
| `setup1.sh` | **Docker Engine 版** — Docker Engine + nvidia-container-toolkit + Python 依存 |
| `setup1_desktop.sh` | **Docker Desktop 版** — Python 依存のみ (Docker は Docker Desktop が管理) |

### Docker Engine 版 (setup1.sh)

```bash
# (1) Docker Engine / NVIDIA Container Toolkit / Python 依存 (内部で必要な箇所のみ sudo)
bash infra/wsl/setup1.sh
```

```bash
# docker グループ反映のため再ログイン
newgrp docker          # または exit → 再接続
```

### Docker Desktop 版 (setup1_desktop.sh)

```bash
# (1) Python 依存のみ (内部で必要な箇所のみ sudo)
bash infra/wsl/setup1_desktop.sh
```

> Docker Desktop 版は docker グループへの追加や再ログインは不要です。

### 共通: setup2.sh

```bash
# (2) ALFWorld データ / .env / Docker イメージ pull
cd ~/AgentBench_Small_For_LLM2025
bash infra/wsl/setup2.sh
```

---

## Step 5: Docker + GPU の動作確認

```bash
docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu22.04 nvidia-smi
```

GPU 情報が表示されれば Docker 経由の GPU アクセスが正常です。

表示されない場合:
1. Docker が起動しているか確認: `sudo systemctl status docker`
2. NVIDIA Container Toolkit がインストールされているか確認: `dpkg -l | grep nvidia-container-toolkit`
3. Docker デーモンを再起動: `sudo systemctl restart docker`

---

## Step 6: vLLM 起動

### 方法 A: docker compose (推奨)

```bash
cd ~/AgentBench_Small_For_LLM2025

# .env を設定
cp .env.example .env
vi .env    # VLLM_MODEL, HUGGING_FACE_HUB_TOKEN を設定
```

`.env`:
```bash
VLLM_MODEL=Qwen/Qwen2.5-7B-Instruct
VLLM_MAX_MODEL_LEN=8192
VLLM_GPU_MEMORY_UTILIZATION=0.90
HUGGING_FACE_HUB_TOKEN=hf_xxxxxxxxxxxxx    # gated model の場合
```

```bash
docker compose up -d
```

ヘルスチェック (起動完了まで 1〜3 分):

```bash
# ステータス確認
docker compose ps

# ログをリアルタイムで確認
docker compose logs -f vllm

# API のヘルスチェック
curl -s http://localhost:8000/health
```

### 方法 B: docker run (直接実行)

```bash
docker run --rm -d --name vllm \
  --gpus all --ipc=host -p 8000:8000 \
  -v ~/.cache/huggingface:/root/.cache/huggingface \
  -e HUGGING_FACE_HUB_TOKEN=hf_xxxxxxxxxxxxx \
  vllm/vllm-openai:v0.13.0 \
  --model "Qwen/Qwen2.5-7B-Instruct" \
  --max-model-len 8192 \
  --gpu-memory-utilization 0.90
```

---

## WSL 固有の注意事項

### メモリ制限

WSL2 はデフォルトで Windows の物理メモリの 50% (最大 8GB) しか使えません。
大きなモデルを扱う場合は `%UserProfile%\.wslconfig` で制限を緩和してください。

```ini
# %UserProfile%\.wslconfig (Windows 側)
[wsl2]
memory=24GB
swap=8GB
```

変更後、PowerShell で `wsl --shutdown` → WSL を再起動。

### ディスク I/O

WSL 内のファイルシステム (`/home/...`) は Windows のファイルシステム (`/mnt/c/...`) より **大幅に高速** です。
リポジトリや HuggingFace キャッシュは必ず WSL 内に置いてください。

```bash
# 良い: WSL ネイティブ
~/AgentBench_Small_For_LLM2025/
~/.cache/huggingface/

# 悪い: Windows マウント (遅い)
/mnt/c/Users/.../AgentBench_Small_For_LLM2025/
```

---

## GPU VRAM とモデルサイズの目安

| GPU | VRAM | 推奨モデルサイズ |
|---|---|---|
| RTX 3060 | 12GB | 〜7B (4bit量子化) |
| RTX 3090 / 4090 | 24GB | 〜14B |
| RTX 5090 | 32GB | 〜14B (余裕あり) |
| A100 / H100 | 40-80GB | 〜70B |

> `gpu-memory-utilization=0.90` はデフォルトで VRAM の 90% を使います。
> OOM が出る場合は `VLLM_GPU_MEMORY_UTILIZATION=0.85` に下げるか、`VLLM_MAX_MODEL_LEN` を小さくしてください。

---

## 推奨スペック (まとめ)

| 項目 | 推奨値 |
|---|---|
| OS | Windows 10/11 + WSL2 (Ubuntu 22.04) |
| GPU | NVIDIA RTX 3090 以上 (VRAM 24GB+) |
| RAM | 32GB 以上 |
| ディスク | SSD 200GB 以上の空き |
| NVIDIA ドライバ | 最新版 (Windows 側) |
| Docker | Docker Engine on WSL (Docker Desktop でも可) |
| vLLM | v0.13.0 |
| MySQL | 9.5.0 |

---

## 次のステップ

[ローカル評価の実行](runbook.md) に進んでください。
