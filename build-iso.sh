#!/usr/bin/env bash
# ============================================
#  build-iso.sh - カスタム Arch Linux ISO 作成
#  install.sh を組み込んで起動時に自動配置する
# ============================================

set -euo pipefail

# --- カラー定義 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

print_step() { echo -e "\n${BLUE}${BOLD}▶ $1${RESET}\n${BLUE}$(printf '─%.0s' {1..44})${RESET}"; }
print_ok()   { echo -e "  ${GREEN}✔${RESET} $1"; }
print_warn() { echo -e "  ${YELLOW}⚠${RESET} $1"; }
print_err()  { echo -e "  ${RED}✘${RESET} $1"; }

# --- 設定 ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_SCRIPT="${SCRIPT_DIR}/install.sh"
WORK_DIR="/var/tmp/archiso-work"   # /tmp(RAM) ではなくディスクを使う
OUT_DIR="${SCRIPT_DIR}/out"
PROFILE_DIR="${WORK_DIR}/archlive"

# ============================================
# 事前チェック
# ============================================

check_requirements() {
  print_step "事前チェック"

  # root チェック
  if [[ "$EUID" -ne 0 ]]; then
    print_err "このスクリプトは root で実行してください。"
    echo "  例: sudo bash build-iso.sh"
    exit 1
  fi

  # ディスク空き容量チェック（最低 10GB 必要）
  local avail_gb
  avail_gb=$(df -BG /var/tmp | awk 'NR==2 {print $4}' | tr -d 'G')
  if (( avail_gb < 10 )); then
    print_err "/var/tmp の空き容量が不足しています（現在: ${avail_gb}GB、必要: 10GB以上）"
    echo "  不要なファイルを削除するか、別のパーティションを使ってください。"
    exit 1
  fi
  print_ok "ディスク空き容量: ${avail_gb}GB（/var/tmp）"

  # 前回の失敗した作業ディレクトリを削除
  if [[ -d "$WORK_DIR" ]]; then
    print_warn "前回のビルドディレクトリが残っています。削除します..."
    rm -rf "$WORK_DIR"
    print_ok "クリーンアップ完了"
  fi
  if ! command -v mkarchiso &>/dev/null; then
    print_warn "archiso がインストールされていません。インストールします..."
    pacman -S --noconfirm archiso
  fi
  print_ok "archiso: $(pacman -Q archiso | awk '{print $2}')"

  # install.sh の存在確認
  if [[ ! -f "$INSTALLER_SCRIPT" ]]; then
    print_err "install.sh が見つかりません: ${INSTALLER_SCRIPT}"
    exit 1
  fi
  print_ok "install.sh: ${INSTALLER_SCRIPT}"
}

# ============================================
# プロファイルの準備
# ============================================

setup_profile() {
  print_step "プロファイルのセットアップ"

  # 作業ディレクトリをクリーン
  rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR" "$OUT_DIR"

  # 公式 releng プロファイルをコピー
  cp -r /usr/share/archiso/configs/releng/ "$PROFILE_DIR"
  print_ok "releng プロファイルをコピー"

  # ============================================
  # install.sh を ISO に組み込む
  # airootfs/root/ に置くと ISO 内の /root/ に入る
  # ============================================
  cp "$INSTALLER_SCRIPT" "${PROFILE_DIR}/airootfs/root/install.sh"
  chmod +x "${PROFILE_DIR}/airootfs/root/install.sh"
  print_ok "install.sh を /root/install.sh として組み込み"

  # ============================================
  # 起動時に案内メッセージを表示する
  # /etc/motd に書き込む
  # ============================================
  cat > "${PROFILE_DIR}/airootfs/etc/motd" << 'MOTD'

  ╔══════════════════════════════════════════╗
  ║     myarchinstall - Arch インストーラー  ║
  ╚══════════════════════════════════════════╝

  インストールを開始するには:

    bash /root/install.sh

  ネットワーク接続（WiFi）が必要な場合:

    iwctl
    [iwd]# station wlan0 connect <SSID>

MOTD
  print_ok "起動メッセージ（/etc/motd）を設定"

  # ============================================
  # kmscon による日本語コンソールと自動ログインの設定
  # ============================================
  
  # kmscon の設定ファイルを作成
  mkdir -p "${PROFILE_DIR}/airootfs/etc/kmscon"
  cat > "${PROFILE_DIR}/airootfs/etc/kmscon/kmscon.conf" << 'EOF'
font-name=monospace
font-size=14
render-engine=pango
login=/usr/bin/login -p -f root
xkb-layout=jp
xkb-model=jp106
EOF
  print_ok "kmscon の設定を設定 (日本語キーボード・フォント・root自動ログイン)"

  # Fontconfig の設定（monospace に Noto Sans CJK JP を優先割り当て）
  mkdir -p "${PROFILE_DIR}/airootfs/etc/fonts"
  cat > "${PROFILE_DIR}/airootfs/etc/fonts/local.conf" << 'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <match>
    <test name="family"><string>monospace</string></test>
    <edit name="family" mode="prepend" binding="strong">
      <string>Noto Sans CJK JP</string>
    </edit>
  </match>
</fontconfig>
EOF
  print_ok "Fontconfig 設定（日本語フォントの優先割り当て）"

  # TTY1 で kmscon を有効化し、通常の getty@tty1 をマスク
  mkdir -p "${PROFILE_DIR}/airootfs/etc/systemd/system/getty.target.wants"
  ln -sf "/usr/lib/systemd/system/kmsconvt@.service" \
    "${PROFILE_DIR}/airootfs/etc/systemd/system/getty.target.wants/kmsconvt@tty1.service"
  ln -sf "/dev/null" "${PROFILE_DIR}/airootfs/etc/systemd/system/getty@tty1.service"
  print_ok "systemd: tty1 の getty を無効化し kmscon を有効化"

  # ============================================
  # .bashrc にインストーラー案内を追加
  # ============================================
  cat >> "${PROFILE_DIR}/airootfs/root/.bashrc" << 'BASHRC'

# myarchinstall 案内
if [[ -f /root/install.sh ]]; then
  echo ""
  echo -e "\033[1;33m  ▶ インストーラーを起動するには:\033[0m bash /root/install.sh"
  echo ""
fi
BASHRC
  print_ok ".bashrc にインストーラー案内を追加"

  # ============================================
  # ISO のラベルをカスタマイズ
  # ============================================
  sed -i "s/^iso_label=.*/iso_label=\"MYARCHINSTALL\"/" \
    "${PROFILE_DIR}/profiledef.sh"
  sed -i "s/^iso_name=.*/iso_name=\"myarchinstall\"/" \
    "${PROFILE_DIR}/profiledef.sh"

  print_ok "ISO ラベル: MYARCHINSTALL"

  # ============================================
  # packages.x86_64 の調整
  # mc を削除（Write failed エラーの原因）
  # 日本語フォントと kmscon を追加
  # ============================================
  local pkg_file="${PROFILE_DIR}/packages.x86_64"

  # mc を削除
  sed -i '/^mc$/d' "$pkg_file"
  print_ok "mc を packages.x86_64 から削除（エラー回避）"

  # パッケージを追加（末尾に追記）
  cat >> "$pkg_file" << 'PKGS'
kmscon
noto-fonts
noto-fonts-cjk
noto-fonts-emoji
terminus-font
PKGS
  print_ok "パッケージ（kmscon、noto-fonts-cjk 等）を追加"

  # ============================================
  # Live 環境のロケール・コンソール設定
  # ============================================

  # locale.conf（日本語ロケール）
  mkdir -p "${PROFILE_DIR}/airootfs/etc"
  cat > "${PROFILE_DIR}/airootfs/etc/locale.conf" << 'EOF'
LANG=ja_JP.UTF-8
EOF

  # vconsole.conf（コンソールキーマップとフォント）
  cat > "${PROFILE_DIR}/airootfs/etc/vconsole.conf" << 'EOF'
KEYMAP=jp106
FONT=ter-v18n
EOF
  print_ok "コンソールキーマップ: jp106、フォント: ter-v18n"

  # locale.gen の作成（ビルド時に locale-gen が自動実行される）
  cat > "${PROFILE_DIR}/airootfs/etc/locale.gen" << 'EOF'
en_US.UTF-8 UTF-8
ja_JP.UTF-8 UTF-8
EOF
  print_ok "locale.gen（ja_JP.UTF-8 有効化）を設定"
}

# ============================================
# ISO ビルド
# ============================================

build_iso() {
  print_step "ISO ビルド開始（数分かかります）"

  mkarchiso -v -w "${WORK_DIR}/build" -o "$OUT_DIR" "$PROFILE_DIR"

  # 生成された ISO を確認
  local iso_file
  iso_file=$(ls -t "${OUT_DIR}"/*.iso 2>/dev/null | head -1)

  if [[ -z "$iso_file" ]]; then
    print_err "ISO の生成に失敗しました。"
    exit 1
  fi

  local size
  size=$(du -sh "$iso_file" | awk '{print $1}')

  echo ""
  echo -e "${GREEN}${BOLD}"
  echo "╔══════════════════════════════════════════╗"
  echo "║          ISO 作成完了！                  ║"
  echo "╚══════════════════════════════════════════╝"
  echo -e "${RESET}"
  echo -e "  ${BOLD}ISO ファイル:${RESET} ${iso_file}"
  echo -e "  ${BOLD}サイズ      :${RESET} ${size}"
  echo ""
  echo -e "  ${BOLD}GNOME Boxes での使い方:${RESET}"
  echo -e "    1. GNOME Boxes を起動"
  echo -e "    2. 「＋」→「仮想マシンを作成」"
  echo -e "    3. 上記 ISO ファイルを選択"
  echo -e "    4. 起動後 ${BOLD}bash /root/install.sh${RESET} を実行"
  echo ""
  echo -e "  ${BOLD}USB に書き込む場合:${RESET}"
  echo -e "    sudo dd if=${iso_file} of=/dev/sdX bs=4M status=progress"
}

# ============================================
# クリーンアップ
# ============================================

cleanup() {
  print_step "作業ディレクトリのクリーンアップ"
  rm -rf "${WORK_DIR}/build"
  print_ok "クリーンアップ完了"
}

# ============================================
# メイン
# ============================================

main() {
  echo -e "${CYAN}${BOLD}"
  echo "╔══════════════════════════════════════════╗"
  echo "║   myarchinstall ISO ビルダー             ║"
  echo "╚══════════════════════════════════════════╝"
  echo -e "${RESET}"

  check_requirements
  setup_profile
  build_iso
  cleanup
}

main "$@"
