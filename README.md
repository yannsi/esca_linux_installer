# archinstall

対話式・日本語UIの Arch Linux 自動インストーラーです。ディスク選択からデスクトップ環境のセットアップまで、ステップごとに質問に答えるだけでインストールが完了します。

カスタム起動ISOを作成するビルドスクリプトも同梱しており、`install.sh` をあらかじめ組み込んだ Live ISO を作成できます。

## 構成

| ファイル | 役割 |
|---|---|
| `install.sh` | Arch Linux 本体の対話式インストーラー |
| `build-iso.sh` | `install.sh` を組み込んだカスタム起動 ISO を作成するビルドスクリプト |

## install.sh の特徴

- 完全日本語対応の対話形式UI（カラー表示・ステップごとの確認）
- `/sys/block` を直接スキャンするディスク検出（`lsblk` 非依存・フリーズに強い）
- パーティション構成、ファイルシステム、ブートローダー（systemd-boot / GRUB）選択
- 複数ユーザー作成、sudo権限、ログインシェル（bash/zsh/fish）の個別設定
- デスクトップ環境（GNOME, KDE, Sway, Hyprland, niri 等）とディスプレイマネージャーの自動セットアップ
- GPU自動検出（NVIDIA/AMD/Intel）とドライバの自動インストール・カーネルパラメータ設定
- 日本語環境（ロケール・フォント・IME）のワンステップ設定
- WiFi、ミラーサーバー、AURヘルパー（yay）、ファイアウォール、印刷機能などの追加設定
- エラー発生時は行番号・コマンド・ログファイルの場所を表示し、トラブルシューティング手順を案内
- 外付けディスクへのインストールにも対応（起動方法の案内付き）

## build-iso.sh の特徴

- 公式 `releng` プロファイルをベースに、`install.sh` を組み込んだカスタム ISO を作成
- 起動直後に `/etc/motd` と `.bashrc` でインストーラーの起動方法を案内
- 日本語コンソール環境（kmscon + Noto Sans CJK JP + jp106キーマップ）を Live 環境にあらかじめ設定
- ビルド前にディスク空き容量や `archiso` の有無を自動チェック

## 必要環境

- Arch Linux（または Arch Linux Live 環境）
- root 権限

`build-iso.sh` の実行には別途 `archiso` パッケージが必要です（未インストールの場合は自動でインストールされます）。

## 使い方

### 1. インストーラーを直接実行する場合

Arch Linux の Live 環境で以下を実行します。

```bash
curl -O https://raw.githubusercontent.com/yannsi/archinstall/main/install.sh
chmod +x install.sh
sudo bash install.sh
```

画面の指示に従ってディスク・ユーザー・デスクトップ環境などを選択していくと、最後にインストール内容のサマリーが表示されます。内容を確認し、「インストールを実行する」を選ぶと処理が始まります。

### 2. カスタム ISO を作成する場合

`install.sh` と `build-iso.sh` を同じディレクトリに置いた状態で実行します。

```bash
git clone https://github.com/yannsi/archinstall.git
cd archinstall
sudo bash build-iso.sh
```

`out/` ディレクトリに ISO ファイルが生成されます。

**GNOME Boxes で試す場合:**
1. GNOME Boxes を起動し「＋」→「仮想マシンを作成」
2. 生成された ISO ファイルを選択して起動
3. 起動後、`bash /root/install.sh` を実行

**USB に書き込んで実機にインストールする場合:**
```bash
sudo dd if=out/myarchinstall.iso of=/dev/sdX bs=4M status=progress
```
（`/dev/sdX` は対象のUSBデバイスに置き換えてください。誤ったデバイスを指定するとデータが消去されるので注意してください）

## トラブルシューティング

インストール中にエラーが発生した場合、エラーメッセージに従って以下を確認してください。

```bash
# 詳細なエラーログを確認
cat /tmp/myarchinstall.log

# 中途半端にマウントされた状態を解除
umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true
```

パーティションテーブルが破損した場合でも、再実行することで自動的にクリーンアップ（`sgdisk --zap-all`）されてやり直せます。

## 注意事項

- `install.sh` の実行は対象ディスクのデータを完全に消去します。実行前に対象ディスクが正しいか必ず確認してください。
- 本スクリプトは自己責任でご利用ください。

## ライセンス

MIT License - 詳細は [`LICENSE`](./LICENSE) を参照してください（[日本語参考訳](./LICENSE.ja.md)も用意していますが、法的効力は英語の原文が優先されます）。
