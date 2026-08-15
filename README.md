# esca-dotfiles

Arch Linux + Niri / Hyprland デスクトップ環境の設定ファイル集です。
統一感のあるパステルテーマ（Catppuccin Mocha / Macchiato）および Esca テーマで構成されています。

## 収録されている設定

- **Window Manager**: Niri, Hyprland (`.config/hypr/hyprland.lua`)
- **Status Bar**: Waybar（Fuzzelラジオ、Chrome/Firefoxランチャー、カレンダー、天気予報、CAVAビジュアライザー内蔵）
- **Terminal**: Alacritty
- **Launcher**: Fuzzel
- **Screen Locker**: Swaylock（Niri）/ Hyprlock（Hyprland）
- **Wallpaper**: swaybg（Niri）/ hyprpaper（Hyprland）
- **Shell Prompt**: Starship
- **Custom Font**: `EscaSymbols.otf` — Esca 専用グリフ（U+100000）を収録
- **Wallpaper Image**: `esca` — テーマの配色サンプル元になっている壁紙

> 電源メニューは wlogout から Fuzzel ベースのものに移行しました。
> wlogout は AUR ビルドが必要で依存も重いのに対し、Fuzzel は
> ランチャーとして既に入っているため追加依存がありません。

---

## 主な機能と操作方法

### Waybar の各モジュール
- **メニュー（  ）**: Fuzzel アプリケーションランチャーを起動
- **ブラウザ（  /  ）**: Firefox / Google Chrome をワンクリック起動（Chrome未インストール時は自動非表示）
- **インターネットラジオ（  ）**:
  - **左クリック**: Fuzzel で作業用BGM・ジャズ・クラシック・アニソン等の局を選択して再生
  - **右クリック**: 再生中のラジオを即時停止
- **メディア情報**: 再生中の楽曲・動画タイトルの表示と操作（クリックで再生/一時停止、右クリックで停止、中クリックでCAVA）
- **音量 / 輝度**: マウスホイールで直感的に音量・明るさを調整
- **天気予報**: 現在の気温・天気を表示（右クリックで地域変更ダイアログ）
- **時計 / カレンダー**:
  - **ホバー**: 月間カレンダーをポップアップ表示（ホイールスクロールで前月/翌月送り）
  - **左クリック**: 時間表示と日付表示の切り替え
- **電源（  ）**: 終了・再起動メニューの表示

---

## 新しい環境でのセットアップ手順

### 1. GitとSSHの準備

```bash
sudo pacman -S git openssh

# SSH鍵の生成（既に鍵を持っている場合はスキップ）
ssh-keygen -t ed25519 -C "your_email@example.com"

# 公開鍵を表示してコピーし、GitHubの設定画面に登録してください
cat ~/.ssh/id_ed25519.pub
```

### 2. リポジトリのクローン

```bash
git clone git@github.com:yannsi/esca-dotfiles.git ~/dotfiles
```

### 3. 設定の適用（自動スクリプト）

付属のセットアップスクリプトを実行すると、自動的にシンボリックリンクが作成されます。

```bash
~/dotfiles/setup.sh
```

### 4. 必要パッケージのインストール

設定を正しく動作させるために、必要なアプリケーションとフォントをインストールします。

```bash
# 共通パッケージ
sudo pacman -S waybar alacritty fuzzel cava mako starship \
               mpv playerctl brightnessctl wireplumber python \
               rofi ranger psmisc zenity mpv-mpris alsa-utils streamlink
```

上記のうち、見落としやすいものを補足します。

| パッケージ | 無いとどうなるか |
|---|---|
| `streamlink` | radiko など mpv に直接渡せない局で、選択しても無反応になる |
| `mpv-mpris` | mpv は既定では MPRIS を喋らないため、メディア情報に曲名が出ない |
| `zenity` | ラジオ・天気の各ダイアログが開かない |
| `alsa-utils` | 音量モジュールの右クリック（alsamixer）が起動しない |
| `psmisc` | スクリプトのプロセス停止処理が動かない |

続いて、使用する WM に応じたパッケージを入れます。

```bash
# Niri を使う場合
sudo pacman -S niri xwayland-satellite swaybg swaylock swayidle \
               xdg-desktop-portal-gnome xdg-desktop-portal-gtk

# Hyprland を使う場合
sudo pacman -S hyprland hyprpaper hyprlock hypridle kitty wofi \
               xorg-xwayland xdg-desktop-portal-hyprland xdg-desktop-portal-gtk
```

```bash
# フォント（アイコン表示に必須）
# いずれも公式リポジトリ（extra）にあるため、AUR ヘルパーは不要です
sudo pacman -S ttf-hack-nerd ttf-jetbrains-mono-nerd noto-fonts-emoji

# Esca 専用グリフ（プロンプトのアンコウ印）を使う場合
sudo mkdir -p /usr/share/fonts/esca
sudo cp ~/dotfiles/EscaSymbols.otf /usr/share/fonts/esca/
fc-cache -f
```

> **アイコンについて**
> Nerd Fonts v3 で U+F500〜U+FD46 の符号位置が削除されました。
> 古い設定ファイルを持ち込むとアイコンが豆腐（□）になることがあります。
> 本リポジトリの設定は v3 の符号位置に更新済みです。

インストール後、一度ログアウトして再ログインするか、再起動してください。
