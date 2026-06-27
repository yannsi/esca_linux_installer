# myarchinstall

対話形式で Arch Linux を自動インストールする Bash スクリプトです。  
初心者から上級者まで、質問に答えるだけでフルセットアップが完了します。

---

## 特徴

- **対話型 UI** — 番号選択と Yes/No で全設定が完結
- **日本語完全対応** — ロケール・キーマップ・IME・日本語フォントを一括設定
- **豊富なデスクトップ環境** — KDE・GNOME・Xfce・Sway・Hyprland・Niri など 8 種類
- **GPU ドライバー自動選択** — NVIDIA / AMD / Intel / 仮想環境を判別してインストール
- **仮想環境自動検出** — VirtualBox・QEMU・VMware のゲストツールを自動追加
- **ドライランモード** — `--dry-run` で実際のインストールを行わず設定確認だけ実行

---

## 必要環境

- Arch Linux Live ISO で起動していること
- インターネット接続があること
- root 権限があること（Live 環境では通常 root で起動）

---

## 使い方

```bash
# リポジトリをクローン
git clone https://github.com/<ユーザー名>/myarchinstall.git
cd myarchinstall

# 実行
bash install.sh

# 設定確認だけしたい場合（ドライラン）
bash install.sh --dry-run
```

---

## インストール手順の流れ

スクリプトを起動すると、以下のステップを対話形式で進めます。

1. **ディスク選択** — インストール先を番号で選択（Live ISO デバイスは自動除外）
2. **パーティション構成** — 自動（EFI + swap + /）/ 自動（swap なし）/ 手動
3. **システム設定** — 言語・タイムゾーン・キーマップ・IME・ホスト名・デュアルブート
4. **ユーザー設定** — root パスワード・一般ユーザー（複数可）・sudo・ログインシェル
5. **ブートローダー** — systemd-boot または GRUB（BIOS は GRUB 固定）
6. **デスクトップ環境** — 以下から選択
7. **ネットワーク** — WiFi バックエンド・systemd-resolved
8. **ミラーサーバー** — reflector 自動選択 / 手動選択 / 現状維持
9. **フォント** — Fira・絵文字・日本語フォントを個別選択
10. **追加パッケージ** — base-devel・zram・AUR ヘルパー・SSH・UFW・GPU ドライバーなど

設定完了後にサマリーを表示し、確認してからインストールを実行します。

---

## 対応デスクトップ環境

| 環境 | 種別 | 難易度 |
|---|---|---|
| KDE Plasma | フル機能 DE | 初心者〜 |
| GNOME | シンプル DE | 初心者〜 |
| Xfce | 軽量 DE | 初心者〜 |
| Budgie | エレガント DE | 初心者〜 |
| COSMIC | 次世代 DE（Rust 製） | 中級〜 |
| Sway | タイリング WM | 上級者向け |
| Hyprland | タイリング WM | 上級者向け |
| Niri | スクロール型タイリング WM | 上級者向け |
| なし | CLI のみ | 上級者向け |

---

## 対応パーティション構成

| 構成 | 内容 |
|---|---|
| 自動 | EFI 512MB + swap 4GB + /（ハイバネートを使う場合） |
| 自動（swap なし） | EFI 512MB + /（zram を使う場合・推奨） |
| 手動 | fdisk を起動して自分でパーティションを作成 |

> **zram について**  
> swap パーティションの代わりに RAM 上に圧縮 swap 領域を作る zram を使うことができます（追加パッケージの選択肢で設定可能）。zram の方が高速でディスク容量を節約できるため、ハイバネートが不要な場合は「swap なし + zram」の組み合わせが推奨です。

---

## 主な選択肢一覧

**ブートローダー**
- systemd-boot（UEFI 推奨）
- GRUB（UEFI / BIOS 両対応）

**WiFi バックエンド**
- iwd（モダン・推奨）
- wpa_supplicant（互換性重視）

**IME（日本語入力）**
- fcitx5 + mozc（推奨）
- fcitx5 + anthy
- ibus + mozc

**GPU ドライバー**
- NVIDIA（プロプライエタリ）
- NVIDIA（Nouveau・オープンソース）
- AMD（AMDGPU）
- Intel
- 仮想環境向け（VMware）

**AUR ヘルパー**（base-devel 選択時のみ）
- yay-bin
- paru

---

## ログ

インストールログは以下に保存されます。エラー発生時の確認に使用してください。

```
/tmp/myarchinstall-YYYYMMDD-HHMMSS.log
```

---

## 注意事項

- **選択したディスクの全データが消去されます。** 実行前に必ずバックアップを取ってください。
- 外付け USB へのインストールも可能ですが、起動には BIOS/UEFI の Boot Order 変更が必要です。
- Windows とのデュアルブートを選択した場合、RTC がローカル時刻モードに設定されます。
- Sway・Hyprland・Niri はキーボード操作が前提の上級者向け環境です。

---

## 動作確認環境

- Arch Linux Live ISO（最新版推奨）
- UEFI / BIOS 両対応
- Bash 4.0 以上（Live ISO には標準搭載）

---

## ライセンス

MIT License
