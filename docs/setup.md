# セットアップスクリプト

ローカル・GCP 共通の環境構築です。マシン固有の準備は先に済ませてください:

- ローカル → [ローカルマシンの環境構築](setup-local.md)
- GCP → [VM の環境構築](setup-gcp.md)

---

## setup-vm.sh

Docker・Python 依存・設定ファイル・Docker イメージをまとめてセットアップします。

```bash
cd ~/AgentBench_Small_For_LLM2025
sudo bash scripts/setup/setup-vm.sh
```

処理内容:

1. Docker Engine のインストール
2. NVIDIA Container Toolkit のインストール
3. ユーザーを docker グループに追加
4. Python 依存パッケージのインストール
5. `.env` / agent config の生成
6. Docker イメージの pull (vLLM, MySQL)

完了後、docker グループの反映のため再ログインが必要です:

```bash
exit
# SSH で再接続、または:
newgrp docker
```

---

## setup-systemd.sh (GCP のみ)

VM 再起動時に vLLM を自動起動させます。**ローカル環境では不要です。**

```bash
sudo bash scripts/setup/setup-systemd.sh
```

セットアップ後の確認:

```bash
systemctl status agentbench-vllm
```

---

## 次のステップ

セットアップが完了したら [評価の実行](runbook.md) に進んでください。
