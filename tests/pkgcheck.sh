#!/usr/bin/env bash
# ============================================
#  公式パッケージ名の定期チェック
# ============================================
# インストーラーが入れる公式パッケージ（pacstrap 分・デスクトップ分・後から
# 個別に入れるもの）が、今の Arch のリポジトリにすべて存在するかを確かめる。
#
# 【目的】Arch では名前変更や提供終了が時々起きる（2025年12月の
# nvidia → nvidia-open など）。インストーラーを変えていなくても、
# Arch 側の変化で「pacstrap が target not found で止まる」状態になりうる。
# GitHub Actions で毎週これを動かし、壊れたらその週のうちに気付けるようにする。
#
# 選択肢の組み合わせ（GPU・仮想環境・デスクトップ・ログイン画面など）を
# ひと通り回して一覧を集め、重複を除いてから1つずつ確かめる。
# 組み合わせ同士は衝突しうる（nvidia と nouveau など）ため、依存解決はせず
# 「名前が存在するか」だけを見る。
#
# 使い方: bash tests/pkgcheck.sh [インストーラーのパス（既定 ./install.sh）]
#   Arch Linux 上で、pacman -Sy 済みの状態で実行する。

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${1:-${ROOT_DIR}/install.sh}"

# インストーラーの関数だけを読み込む（main は実行されない）
# 【重要】source の前に引数を空にすること。source した側の "$@" は
# インストーラーの引数解析に渡るため、このスクリプトの引数（パス）が
# 「不明なオプション」として弾かれる。
set --
# shellcheck source=../install.sh
source "$SCRIPT"
set +euo pipefail
trap - ERR EXIT INT TERM
CONFIG[log_file]=/dev/null
CONFIG[dry_run]=no

declare -A ALL=()
_add() { local p; for p in "$@"; do [[ -n "$p" ]] && ALL[$p]=1; done; }

# --- 全体で共通の「最大構成」---
# 一般ユーザーに zsh / fish を選んだとき・GRUB + Windows 共存・SSH / ufw・
# AUR 関連（git / base-devel）が入る分岐をすべて通す。
CONFIG[users]="a||yes|zsh|wheel
b||yes|fish|wheel"
CONFIG[boot_mode]="uefi"
CONFIG[dualboot_windows]="yes"
CONFIG[extra_ssh]="yes"
CONFIG[extra_ufw]="yes"
CONFIG[extra_base_devel]="yes"
CONFIG[extra_zram]="yes"
CONFIG[extra_pkgs]=""
CONFIG[aur_helper]="yay"
CONFIG[install_chrome]="yes"
CONFIG[install_ytfzf]="yes"
CONFIG[install_office]="yes"
CONFIG[japanese_env]="yes"
CONFIG[font_pkgs]="noto-fonts noto-fonts-cjk noto-fonts-emoji adobe-source-han-sans-jp-fonts adobe-source-han-serif-jp-fonts ttf-fira-code ttf-nerd-fonts-symbols-mono"

# --- pacstrap 分 ---
for _cpu in GenuineIntel AuthenticAMD; do
for _gpu in nvidia nouveau amdgpu intel virtual none; do
for _virt in none oracle kvm vmware; do
for _desk in none gnome xfce; do          # intel は Wayland / X11 で中身が変わる
for _bl in systemd-boot grub; do
for _wifi in iwd wpa_supplicant; do
for _ime in fcitx5-mozc fcitx5-anthy; do
  CONFIG[cpu_vendor]=$_cpu; CONFIG[gpu_driver]=$_gpu; CONFIG[virt_env]=$_virt
  CONFIG[desktop]=$_desk; CONFIG[bootloader]=$_bl; CONFIG[wifi_backend]=$_wifi
  CONFIG[jp_ime]=$_ime
  _l=(); _collect_pacstrap_pkgs _l quiet; _add "${_l[@]}"
done; done; done; done; done; done; done

# --- デスクトップ分 ---
for _desk in kde gnome xfce budgie cosmic hyprland niri; do
for _dm in sddm gdm lightdm cosmic-greeter greetd none; do
for _kde in minimal standard full; do
  CONFIG[desktop]=$_desk; CONFIG[dm]=$_dm; CONFIG[kde_apps]=$_kde
  _c=(); _d=(); _desktop_pkg_lists _c _d; _add "${_c[@]}" "${_d[@]}"
done; done; done

# --- 一覧の関数を通らず、個別に入れているもの ---
# yt-fzf のクリップボード連携（X11 / Wayland）
_add xclip wl-clipboard

# --- 確認 ---
mapfile -t pkgs < <(printf '%s\n' "${!ALL[@]}" | sort)
missing=() aliased=()
for p in "${pkgs[@]}"; do
  pacman -Si -- "$p" > /dev/null 2>&1 && continue
  pacman -Sg -- "$p" > /dev/null 2>&1 && continue
  # 名前そのものは無くても、別のパッケージが provides で引き継いでいれば
  # pacman -S は通る（p7zip → 7zip のような改名）。インストールは止まらないので
  # 失敗にはせず、「新しい名前に書き換えたほうがよい」として別に報告する。
  if LC_ALL=C pacman -Sp --noconfirm --print-format '%n' -- "$p" > /dev/null 2>&1 < /dev/null; then
    aliased+=("$p")
    continue
  fi
  missing+=("$p")
done

echo "確認したパッケージ: ${#pkgs[@]} 件（$(basename "$SCRIPT")）"
if [[ "${#aliased[@]}" -gt 0 ]]; then
  echo ""
  echo "旧名のまま（別のパッケージが引き継いでいるため、インストールは通る）: ${#aliased[@]} 件"
  printf '  - %s\n' "${aliased[@]}"
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    for p in "${aliased[@]}"; do
      echo "::warning title=旧名のパッケージ（新しい名前への書き換えを推奨）::${p}"
    done
  fi
fi
if [[ "${#missing[@]}" -gt 0 ]]; then
  echo ""
  echo "公式リポジトリに見つからないパッケージ: ${#missing[@]} 件"
  printf '  - %s\n' "${missing[@]}"
  echo ""
  echo "名前が変わったか、提供が終わった可能性があります。"
  echo "Arch のニュース (https://archlinux.org/news/) とパッケージ検索で確認してください。"
  # GitHub Actions では注釈（annotation）としても出す。ログを開かなくても、
  # 実行結果の画面とメール通知の一覧に、見つからない名前がそのまま表示される。
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    for p in "${missing[@]}"; do
      echo "::error title=公式リポジトリに見つからないパッケージ::${p}"
    done
  fi
  exit 1
fi
echo "結果: すべて存在します"
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  echo "::notice title=パッケージ名の確認::${#pkgs[@]} 件すべて存在します"
fi
