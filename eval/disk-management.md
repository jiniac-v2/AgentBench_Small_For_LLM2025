# ディスク容量管理ガイド

GCP VM (200GB) で複数モデルを連続評価する際のディスク管理に関するドキュメントです。

---

## ディスクを消費する主な要因

| 要因 | 場所 | サイズ目安 | 自動クリーンアップ |
|---|---|---|---|
| HF モデルキャッシュ | `~/.cache/huggingface/hub/` | 10-50 GB/モデル | あり (step1) |
| Docker images | `/var/lib/docker/` | 10-30 GB | あり (step1) |
| Docker コンテナログ | `/var/lib/docker/containers/` | 無制限 → **150MB上限** | あり (docker-compose) |
| Docker build cache | `/var/lib/docker/` | 数 GB | あり (step1) |
| 評価出力 (outputs/) | `outputs/` | 数百 MB/モデル | なし |
| Prefect DB | `~/.prefect/` | 数百 MB | なし |

---

## パイプラインに組み込まれた自動対策

### 1. HF モデルキャッシュの自動削除 (`step1_start_vllm.sh`)

各モデル評価の開始時に `~/.cache/huggingface/hub/` を削除します。
vLLM コンテナが root で書き込むため、通常の `rm` が失敗した場合は `sudo` にフォールバックします。

```bash
# step1_start_vllm.sh より抜粋
HF_CACHE="${HF_CACHE_DIR:-${HOME}/.cache/huggingface}"
if [ -d "${HF_CACHE}/hub" ]; then
    if rm -rf "${HF_CACHE}/hub" 2>/dev/null; then
        echo "削除完了"
    else
        sudo rm -rf "${HF_CACHE}/hub"  # root 所有ファイル対策
    fi
fi
```

**注意**: モデルは毎回ダウンロードされるため、ネットワーク速度に依存します (7B モデルで約 5 分)。

### 2. Docker 不要リソースの自動削除 (`step1_start_vllm.sh`)

`docker compose down` の直後に `docker system prune -f` を実行し、
停止コンテナ・dangling image・build cache を毎回クリーンアップします。

### 3. コンテナログのローテーション (`docker-compose.yaml`)

```yaml
logging:
  driver: json-file
  options:
    max-size: "50m"
    max-file: "3"
```

vLLM コンテナのログを 50MB x 3 ファイル = 最大 150MB に制限しています。
これがないと、推論リクエストのログが無制限に膨張します。

### 4. ディスク空き容量ガード (`runbook.py`)

各モデル評価の開始前に空き容量を確認し、**20GB 未満の場合はパイプラインを中断**します。
Slack にも通知が飛びます。

```python
DISK_MIN_GB = 20

def check_disk_space(min_gb=DISK_MIN_GB):
    usage = shutil.disk_usage("/home")
    avail_gb = usage.free / (1024 ** 3)
    return avail_gb >= min_gb, round(avail_gb, 1)
```

この安全弁により、ディスク 100% → DNS 死亡 → git 不能 → CSV 破損 という連鎖障害を防止します。

---

## 手動でのディスク確認・対策

### 空き容量の確認

```bash
# 全体の空き容量
df -h /home

# 主要ディレクトリごとの使用量
du -sh ~/.cache/huggingface/hub/ 2>/dev/null   # HF モデルキャッシュ
du -sh /var/lib/docker/                         # Docker 全体 (sudo 必要)
du -sh ~/AgentBench_Small_For_LLM2025/outputs/  # 評価結果
du -sh ~/.prefect/                              # Prefect DB
```

### 緊急時のディスク解放

```bash
# 1. HF モデルキャッシュ削除 (最大の効果)
sudo rm -rf ~/.cache/huggingface/hub

# 2. Docker の全不要リソース削除 (イメージも含む)
docker system prune -af

# 3. 古い評価結果の削除 (必要に応じて)
ls -lt ~/AgentBench_Small_For_LLM2025/outputs/
# rm -rf ~/AgentBench_Small_For_LLM2025/outputs/<不要なディレクトリ>

# 4. Prefect DB リセット (壊れた場合)
rm -rf ~/.prefect/*.db
```

### ディスク 100% になった場合の復旧手順

ディスクが満杯になると DNS 解決が失敗し、git/pip/docker pull 等すべてのネットワーク操作が不能になります。

```bash
# 1. まずディスクを空ける (ネットワーク不要な操作から)
sudo rm -rf ~/.cache/huggingface/hub
docker system prune -af

# 2. DNS の復旧確認
ping github.com

# 3. DNS が復旧しない場合、デーモンを再起動
sudo systemctl restart systemd-resolved

# 4. それでもダメなら一時的に Google DNS を使う
echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf
```

**GCE 固有の注意**: GCE VM は DNS にメタデータサーバー (`169.254.169.254`) を使用しています。
ディスク枯渇で `systemd-resolved` のキャッシュが書けなくなると DNS が停止します。
容量を確保すれば自然に復旧することが多いです。

---

## 設計判断: なぜ HF キャッシュを毎回削除するか

当初は「キャッシュを保持してダウンロード時間を節約する」設計でしたが、
200GB ディスクに対して 10-50GB/モデルのキャッシュが蓄積すると 4-5 モデルで満杯になります。

| 方式 | メリット | デメリット |
|---|---|---|
| キャッシュ保持 | ダウンロード時間節約 | 4-5 モデルでディスク満杯 |
| **毎回削除 (現行)** | ディスク枯渇を確実に防止 | 毎回 5-10 分のダウンロード |

ディスク 100% になるとパイプライン全体が壊れ、手動復旧が必要になるため、
毎回削除する方が運用上安全と判断しました。
