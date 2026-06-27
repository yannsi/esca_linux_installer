#!/usr/bin/env bash
# ============================================
#  myarchinstall - Arch Linux インストーラー
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

# --- 引数解析 & ログ初期化 ---
DRY_RUN="no"
for arg in "$@"; do
  if [[ "$arg" == "--dry-run" ]]; then
    DRY_RUN="yes"
  fi
done

LOG_FILE="/tmp/myarchinstall-$(date +%Y%m%d-%H%M%S).log"

# --- 設定を格納する連想配列 ---
declare -A CONFIG=(
  [disk]=""
  [disk_is_external]="no"
  [hostname]=""
  [username]=""
  [timezone]="Asia/Tokyo"
  [locale]="ja_JP.UTF-8"
  [keymap]="jp106"
  [bootloader]="systemd-boot"
  [boot_mode]=""
  [partition_scheme]=""
  [desktop]="none"
  [kde_apps]="none"
  [dm]="none"
  [root_password]=""
  [user_password]=""
  [user_sudo]="no"
  [users]=""
  [users_count]="0"
  [japanese_env]="no"
  [jp_font]="no"
  [jp_ime]="none"
  [wifi_backend]="none"
  [use_resolved]="no"
  [mirror_mode]="keep"
  [mirror_host]=""
  [dualboot_windows]="no"
  [extra_base_devel]="no"
  [extra_zram]="no"
  [extra_pkgs]=""
  [font_pkgs]=""
  [font_setup_fontconfig]="no"
  [dry_run]="$DRY_RUN"
  [log_file]="$LOG_FILE"
  [gpu_driver]="none"
  [aur_helper]="none"
  [extra_ssh]="no"
  [extra_ufw]="no"
  [virt_env]="none"
)

# パーティションデバイス名（nvme0n1 → nvme0n1p1, sda → sda1 など）
part_suffix() {
  local disk="$1"
  local num="$2"
  # /dev/ プレフィックスを除去して統一
  disk="${disk#/dev/}"
  if [[ "$disk" =~ nvme|mmcblk ]]; then
    echo "/dev/${disk}p${num}"
  else
    echo "/dev/${disk}${num}"
  fi
}

# ============================================
# ユーティリティ関数
# ============================================

print_header() {
  clear
  echo -e "${CYAN}${BOLD}"
  echo "╔══════════════════════════════════════════╗"
  echo "║     myarchinstall - Arch インストーラー  ║"
  echo "╚══════════════════════════════════════════╝"
  echo -e "${RESET}"
}

print_step() {
  echo -e "\n${BLUE}${BOLD}▶ $1${RESET}"
  echo -e "${BLUE}$(printf '─%.0s' {1..44})${RESET}"
}

print_ok()   { echo -e "  ${GREEN}✔${RESET} $1"; }
print_warn() { echo -e "  ${YELLOW}⚠${RESET} $1"; }
print_err()  { echo -e "  ${RED}✘${RESET} $1"; }

run_cmd() {
  # コマンドを実行しログに残す。失敗時はエラー表示して終了
  local desc="$1"; shift
  echo -ne "  ${CYAN}…${RESET} ${desc}..."
  if [[ "${CONFIG[dry_run]}" == "yes" ]]; then
    echo -e "\r  ${YELLOW}⚠${RESET} ${desc} (ドライラン - スキップ)"
    return 0
  fi
  if "$@" >> "${CONFIG[log_file]}" 2>&1; then
    echo -e "\r  ${GREEN}✔${RESET} ${desc}   "
  else
    echo -e "\r  ${RED}✘${RESET} ${desc} — 失敗"
    print_err "ログ: ${CONFIG[log_file]}"
    exit 1
  fi
}

ask() {
  local prompt="$1"
  local default="${2:-}"
  local answer
  if [[ -n "$default" ]]; then
    echo -ne "  ${BOLD}${prompt}${RESET} [${default}]: "
  else
    echo -ne "  ${BOLD}${prompt}${RESET}: "
  fi
  read -r answer
  echo "${answer:-$default}"
}

ask_password() {
  local prompt="$1"
  local pw1 pw2
  while true; do
    echo -ne "  ${BOLD}${prompt}${RESET}: "
    read -rs pw1; echo
    echo -ne "  ${BOLD}（確認）${prompt}${RESET}: "
    read -rs pw2; echo
    if [[ "$pw1" == "$pw2" ]]; then
      echo "$pw1"
      return
    fi
    print_err "パスワードが一致しません。もう一度入力してください。"
  done
}

confirm() {
  local prompt="${1:-続けますか？}"
  local answer
  echo -ne "  ${BOLD}${prompt}${RESET} [y/N]: "
  read -r answer
  [[ "$answer" =~ ^[yY]$ ]]
}

select_from_list() {
  local prompt="$1"
  shift
  local options=("$@")
  echo -e "  ${BOLD}${prompt}${RESET}"
  for i in "${!options[@]}"; do
    printf "    ${CYAN}%2d)${RESET} %s\n" "$((i+1))" "${options[$i]}"
  done
  local choice
  while true; do
    echo -ne "  番号を入力: "
    read -r choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
      echo "${options[$((choice-1))]}"
      return
    fi
    print_err "1〜${#options[@]} の番号を入力してください。"
  done
}

get_mirror_country() {
  case "${CONFIG[locale]:-}" in
    ja_JP*) echo "Japan" ;;
    en_US*) echo "United States" ;;
    en_GB*) echo "United Kingdom" ;;
    de_DE*) echo "Germany" ;;
    fr_FR*) echo "France" ;;
    *)
      # タイムゾーンから推測を試みる
      case "${CONFIG[timezone]:-}" in
        Asia/Tokyo|Asia/Osaka) echo "Japan" ;;
        America/*) echo "United States" ;;
        Europe/London) echo "United Kingdom" ;;
        Europe/Berlin) echo "Germany" ;;
        Europe/Paris) echo "France" ;;
        *) echo "" ;; # 空の場合は国指定なし（全世界）
      esac
      ;;
  esac
}

# ============================================
# ステップ 1: ディスク選択
# ============================================

step_disk() {
  print_step "ディスク選択"

  # Arch ISO が載っているデバイスを特定して除外
  # （/run/archiso/bootmnt または /run/miso など にマウントされている親デバイスを除く）
  local iso_dev=""
  iso_dev=$(findmnt -n -o SOURCE /run/archiso/bootmnt 2>/dev/null || \
            findmnt -n -o SOURCE /run/miso 2>/dev/null || true)
  # パーティション番号を除いてデバイス名だけ取り出す（例: /dev/sda1 → sda）
  if [[ -n "$iso_dev" ]]; then
    iso_dev=$(lsblk -no PKNAME "$iso_dev" 2>/dev/null || \
              echo "$iso_dev" | sed 's|/dev/||; s|[0-9]*$||; s|p[0-9]*$||')
  fi

  # ディスク一覧を構築（loop・光学・ISO デバイスを除外）
  local disks=()
  while IFS= read -r line; do
    local devname
    devname=$(echo "$line" | awk '{print $1}' | sed 's|/dev/||')
    # ISO デバイスをスキップ
    [[ -n "$iso_dev" && "$devname" == "$iso_dev" ]] && continue
    # 外付けかどうかを判定してラベルを付ける
    local tran
    tran=$(lsblk -dno TRAN "/dev/${devname}" 2>/dev/null || true)
    local label=""
    case "$tran" in
      usb)  label=" [外付け USB]" ;;
      sata) label=" [SATA]" ;;
      nvme) label=" [NVMe]" ;;
      *)    [[ -n "$tran" ]] && label=" [${tran}]" ;;
    esac
    disks+=("${line}${label}")
  done < <(lsblk -dno NAME,SIZE,MODEL 2>/dev/null | grep -v "loop\|sr" | \
           awk '{print "/dev/"$1" ("$2") "$3}')

  if [[ ${#disks[@]} -eq 0 ]]; then
    print_err "インストール先ディスクが見つかりません。"
    exit 1
  fi

  # ISO デバイスを除外した旨を表示
  if [[ -n "$iso_dev" ]]; then
    print_ok "Arch ISO デバイス (/dev/${iso_dev}) を候補から除外しました"
  fi

  echo ""
  local selected
  selected=$(select_from_list "インストール先ディスクを選択してください:" "${disks[@]}")
  CONFIG[disk]=$(echo "$selected" | awk '{print $1}')

  # 外付けディスクかどうかを記録（完了メッセージで案内するため）
  local sel_tran
  sel_tran=$(lsblk -dno TRAN "${CONFIG[disk]}" 2>/dev/null || true)
  if [[ "$sel_tran" == "usb" ]]; then
    CONFIG[disk_is_external]="yes"
    print_warn "外付け USB デバイスが選択されました"
  else
    CONFIG[disk_is_external]="no"
  fi

  print_warn "選択: ${CONFIG[disk]}"
  print_warn "このディスクの全データが消去されます！"

  if ! confirm "本当によろしいですか？"; then
    print_err "中断しました。"
    exit 1
  fi
  print_ok "ディスク: ${CONFIG[disk]}"
}

# ============================================
# ステップ 2: パーティション構成
# ============================================

step_partition_scheme() {
  print_step "パーティション構成"

  local scheme
  scheme=$(select_from_list "パーティション構成を選択:" \
    "自動（推奨） - EFI 512M + swap 4G + /" \
    "自動 - EFI 512M + / のみ（swap なし）" \
    "手動（fdisk を起動）")

  case "$scheme" in
    "自動（推奨） - EFI 512M + swap 4G + /") CONFIG[partition_scheme]="auto_swap" ;;
    "自動 - EFI 512M + / のみ（swap なし）")  CONFIG[partition_scheme]="auto_noswap" ;;
    "手動（fdisk を起動）")                    CONFIG[partition_scheme]="manual" ;;
  esac
  print_ok "パーティション構成: ${CONFIG[partition_scheme]}"
}

# ============================================
# ステップ 3: システム設定
# ============================================

step_system() {
  print_step "システム設定"

  # --- 言語プリセット ---
  local lang_preset
  lang_preset=$(select_from_list "言語・地域の設定:" \
    "日本語（推奨） - ロケール/キーマップ/タイムゾーンを一括設定" \
    "English (US)" \
    "手動で個別設定")

  case "$lang_preset" in
    "日本語（推奨） - ロケール/キーマップ/タイムゾーンを一括設定")
      CONFIG[locale]="ja_JP.UTF-8"
      CONFIG[keymap]="jp106"
      CONFIG[timezone]="Asia/Tokyo"
      CONFIG[japanese_env]="yes"
      print_ok "ロケール  : ja_JP.UTF-8"
      print_ok "キーマップ: jp106"
      print_ok "タイムゾーン: Asia/Tokyo"
      ;;
    "English (US)")
      CONFIG[locale]="en_US.UTF-8"
      CONFIG[keymap]="us"
      CONFIG[timezone]="UTC"
      CONFIG[japanese_env]="no"
      print_ok "ロケール  : en_US.UTF-8"
      print_ok "キーマップ: us"
      print_ok "タイムゾーン: UTC"
      ;;
    "手動で個別設定")
      CONFIG[japanese_env]="no"

      local tz
      tz=$(select_from_list "タイムゾーン:" \
        "Asia/Tokyo" "Asia/Osaka" "UTC" "手動入力")
      [[ "$tz" == "手動入力" ]] && tz=$(ask "タイムゾーン（例: Europe/London）" "UTC")
      CONFIG[timezone]="$tz"
      print_ok "タイムゾーン: ${CONFIG[timezone]}"

      local locale
      locale=$(select_from_list "ロケール:" \
        "ja_JP.UTF-8" "en_US.UTF-8" "en_GB.UTF-8")
      CONFIG[locale]="$locale"
      print_ok "ロケール: ${CONFIG[locale]}"

      local keymap
      keymap=$(select_from_list "コンソールキーマップ:" \
        "jp106" "us" "uk" "手動入力")
      [[ "$keymap" == "手動入力" ]] && keymap=$(ask "キーマップ" "us")
      CONFIG[keymap]="$keymap"
      print_ok "キーマップ: ${CONFIG[keymap]}"

      # 手動設定でも ja_JP を選んだら日本語環境フラグを立てる
      if [[ "${CONFIG[locale]}" == "ja_JP.UTF-8" ]]; then
        CONFIG[japanese_env]="yes"
      fi
      ;;
  esac

  # --- 日本語環境オプション（プリセット or 手動で ja を選んだ場合） ---
  if [[ "${CONFIG[japanese_env]}" == "yes" ]]; then
    echo ""
    echo -e "  ${CYAN}${BOLD}── 日本語環境オプション ──${RESET}"

    CONFIG[jp_font]="yes"   # フォントステップで詳細選択
    CONFIG[jp_ime]="none"

    if confirm "Input Method（IME）をインストールしますか？"; then
      local ime
      ime=$(select_from_list "IME を選択:" \
        "fcitx5 + mozc（汎用・推奨）" \
        "fcitx5 + anthy" \
        "ibus + mozc" \
        "インストールしない")
      case "$ime" in
        "fcitx5 + mozc（汎用・推奨）") CONFIG[jp_ime]="fcitx5-mozc" ;;
        "fcitx5 + anthy")              CONFIG[jp_ime]="fcitx5-anthy" ;;
        "ibus + mozc")                 CONFIG[jp_ime]="ibus-mozc" ;;
        "インストールしない")          CONFIG[jp_ime]="none" ;;
      esac
      [[ "${CONFIG[jp_ime]}" != "none" ]] && print_ok "IME: ${CONFIG[jp_ime]}"
    else
      CONFIG[jp_ime]="none"
    fi
  else
    CONFIG[jp_font]="no"
    CONFIG[jp_ime]="none"
  fi

  # --- ホスト名 ---
  echo ""
  CONFIG[hostname]=$(ask "ホスト名" "archlinux")
  while [[ -z "${CONFIG[hostname]}" ]]; do
    print_err "ホスト名は必須です。"
    CONFIG[hostname]=$(ask "ホスト名" "archlinux")
  done
  print_ok "ホスト名: ${CONFIG[hostname]}"

  # --- Windows デュアルブート ---
  echo ""
  if confirm "Windows と共存（デュアルブート）しますか？"; then
    CONFIG[dualboot_windows]="yes"
    print_warn "Windows はハードウェアクロックをローカル時刻として扱います。"
    print_warn "RTC をローカル時刻に設定します（Windows との時刻ずれを防止）。"
    print_ok "RTC モード: localtime（Windows 互換）"
  else
    CONFIG[dualboot_windows]="no"
    print_ok "RTC モード: UTC（推奨）"
  fi

  # --- GPU ドライバーの選択 ---
  echo ""
  local gpu
  gpu=$(select_from_list "GPU ドライバーを選択してください（グラフィック表示に重要）:" \
    "NVIDIA (公式プロプライエタリドライバー)" \
    "NVIDIA (オープンソース - Nouveau)" \
    "AMD (オープンソース - Radeon/AMDGPU)" \
    "Intel (オープンソース)" \
    "仮想環境向け (VirtualBox/VMware 共通)" \
    "インストールしない (カーネル内蔵の基本ドライバのみ)")

  case "$gpu" in
    "NVIDIA (公式プロプライエタリドライバー)") CONFIG[gpu_driver]="nvidia" ;;
    "NVIDIA (オープンソース - Nouveau)")      CONFIG[gpu_driver]="nouveau" ;;
    "AMD (オープンソース - Radeon/AMDGPU)")   CONFIG[gpu_driver]="amdgpu" ;;
    "Intel (オープンソース)")                  CONFIG[gpu_driver]="intel" ;;
    "仮想環境向け (VirtualBox/VMware 共通)")   CONFIG[gpu_driver]="virtual" ;;
    *)                                         CONFIG[gpu_driver]="none" ;;
  esac
  print_ok "GPU ドライバー: ${CONFIG[gpu_driver]}"
}

# ============================================
# ステップ 4: ユーザー設定
# ============================================

step_users() {
  print_step "ユーザー設定"

  # --- root パスワード ---
  echo -e "  ${YELLOW}root パスワードを設定します${RESET}"
  local root_pw
  while true; do
    root_pw=$(ask_password "root パスワード")
    if [[ ${#root_pw} -lt 8 ]]; then
      print_err "パスワードは8文字以上にしてください。"
      continue
    fi
    break
  done
  CONFIG[root_password]="$root_pw"
  print_ok "root パスワード設定済み"

  # --- 一般ユーザー（複数対応） ---
  CONFIG[users]=""          # "user1:pw1:sudo:bash user2:pw2:nosudo:zsh" 形式で蓄積
  CONFIG[users_count]=0

  while true; do
    echo ""
    if [[ "${CONFIG[users_count]}" -eq 0 ]]; then
      confirm "一般ユーザーを作成しますか？" || { CONFIG[username]=""; break; }
    else
      confirm "さらにユーザーを追加しますか？" || break
    fi

    # ユーザー名
    local uname
    while true; do
      uname=$(ask "ユーザー名")
      if [[ -z "$uname" ]]; then
        print_err "ユーザー名は必須です。"
        continue
      fi
      if [[ ! "$uname" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        print_err "小文字英数字・アンダースコア・ハイフンのみ使用できます（先頭は英字）。"
        continue
      fi
      # 重複チェック
      if [[ -n "${CONFIG[users]}" ]] && echo "${CONFIG[users]}" | grep -q "^${uname}|"; then
        print_err "そのユーザー名はすでに追加されています。"
        continue
      fi
      break
    done

    # パスワード
    local upw
    while true; do
      upw=$(ask_password "${uname} のパスワード")
      if [[ ${#upw} -lt 8 ]]; then
        print_err "パスワードは8文字以上にしてください。"
        continue
      fi
      break
    done

    # sudo 権限
    local usudo="no"
    if confirm "${uname} に sudo（管理者権限）を付与しますか？"; then
      local sudo_type
      sudo_type=$(select_from_list "sudo の種類:" \
        "通常 sudo（実行時にパスワードを求める・推奨）" \
        "NOPASSWD（パスワードなしで sudo 実行）")
      case "$sudo_type" in
        "通常 sudo（実行時にパスワードを求める・推奨）") usudo="yes" ;;
        "NOPASSWD（パスワードなしで sudo 実行）")        usudo="nopasswd" ;;
      esac
    fi

    # ログインシェル
    local ushell
    ushell=$(select_from_list "${uname} のログインシェル:" \
      "bash  - デフォルト・安定" \
      "zsh   - 高機能・補完が強力" \
      "fish  - ユーザーフレンドリー・シンタックスハイライト")
    case "$ushell" in
      "bash  - デフォルト・安定")                       ushell="bash" ;;
      "zsh   - 高機能・補完が強力")                     ushell="zsh" ;;
      "fish  - ユーザーフレンドリー・シンタックスハイライト") ushell="fish" ;;
    esac

    # 追加グループ
    local ugroups="wheel,audio,video,storage,optical,input"

    # リストに追記（区切り文字は | ）
    local entry="${uname}|${upw}|${usudo}|${ushell}|${ugroups}"
    if [[ -z "${CONFIG[users]}" ]]; then
      CONFIG[users]="$entry"
    else
      CONFIG[users]="${CONFIG[users]}
${entry}"
    fi
    CONFIG[users_count]=$(( CONFIG[users_count] + 1 ))

    # 最初のユーザーを代表として CONFIG[username] に保持（サマリー表示用）
    if [[ "${CONFIG[users_count]}" -eq 1 ]]; then
      CONFIG[username]="$uname"
      CONFIG[user_sudo]="$usudo"
    fi

    print_ok "ユーザー追加: ${uname} (sudo: ${usudo}, shell: ${ushell})"
  done

  # ユーザー一覧を表示
  if [[ "${CONFIG[users_count]}" -gt 0 ]]; then
    echo ""
    print_ok "作成予定ユーザー一覧:"
    while IFS='|' read -r n _ s sh _; do
      echo -e "    ${CYAN}•${RESET} ${n}  sudo: ${s}  shell: ${sh}"
    done <<< "${CONFIG[users]}"
  fi
}


# ============================================
# ステップ 5: ブートローダー
# ============================================

detect_boot_mode() {
  if [[ -d /sys/firmware/efi/efivars ]]; then
    echo "uefi"
  else
    echo "bios"
  fi
}

step_bootloader() {
  print_step "ブートローダー"

  local boot_mode
  boot_mode=$(detect_boot_mode)
  CONFIG[boot_mode]="$boot_mode"

  if [[ "$boot_mode" == "uefi" ]]; then
    print_ok "ファームウェア: UEFI 検出"

    local bl
    bl=$(select_from_list "ブートローダーを選択:" \
      "systemd-boot（推奨・シンプル・追加パッケージ不要）" \
      "GRUB（マルチブートや特殊構成向け）")

    case "$bl" in
      "systemd-boot（推奨・シンプル・追加パッケージ不要）") CONFIG[bootloader]="systemd-boot" ;;
      "GRUB（マルチブートや特殊構成向け）")                  CONFIG[bootloader]="grub" ;;
    esac
  else
    print_warn "ファームウェア: BIOS（レガシー）検出"
    print_warn "systemd-boot は UEFI 専用のため、GRUB を使用します。"
    CONFIG[bootloader]="grub"
  fi

  print_ok "ブートローダー: ${CONFIG[bootloader]}"
}

# ============================================
# ステップ 6: デスクトップ環境
# ============================================

step_desktop() {
  print_step "デスクトップ環境（任意）"

  local de
  de=$(select_from_list "デスクトップ環境を選択:" \
    "なし（最小構成・CLI）" \
    "KDE Plasma  - 高機能・Wayland/X11" \
    "GNOME       - シンプル・Wayland 推奨" \
    "Xfce        - 軽量・X11 安定" \
    "Budgie      - エレガント・Wayland 専用" \
    "COSMIC      - 新世代・Rust 製・Wayland" \
    "Sway        - タイル型 WM・Wayland（上級者向け）" \
    "Hyprland    - アニメーション・タイル型・Wayland（上級者向け）" \
    "Niri        - スクロール型タイル・Wayland（上級者向け）")

  case "$de" in
    "なし（最小構成・CLI）")                      CONFIG[desktop]="none" ;;
    "KDE Plasma  - 高機能・Wayland/X11")          CONFIG[desktop]="kde" ;;
    "GNOME       - シンプル・Wayland 推奨")        CONFIG[desktop]="gnome" ;;
    "Xfce        - 軽量・X11 安定")               CONFIG[desktop]="xfce" ;;
    "Budgie      - エレガント・Wayland 専用")       CONFIG[desktop]="budgie" ;;
    "COSMIC      - 新世代・Rust 製・Wayland")       CONFIG[desktop]="cosmic" ;;
    "Sway        - タイル型 WM・Wayland（上級者向け）")          CONFIG[desktop]="sway" ;;
    "Hyprland    - アニメーション・タイル型・Wayland（上級者向け）") CONFIG[desktop]="hyprland" ;;
    "Niri        - スクロール型タイル・Wayland（上級者向け）")    CONFIG[desktop]="niri" ;;
  esac

  # KDE のみ: アプリ規模を選択
  if [[ "${CONFIG[desktop]}" == "kde" ]]; then
    echo ""
    local kde_apps
    kde_apps=$(select_from_list "KDE アプリの規模を選択:" \
      "最小（上級者・開発者向け） - plasma-desktop のみ（約500MB）" \
      "標準  - plasma-meta + 基本アプリ（約1.5GB・推奨）" \
      "フル  - kde-applications-meta 全部入り（約4GB）")
    case "$kde_apps" in
      "最小（上級者・開発者向け）"*)     CONFIG[kde_apps]="minimal" ;;
      "標準  - plasma-meta + 基本アプリ（約1.5GB・推奨）") CONFIG[kde_apps]="standard" ;;
      "フル  - kde-applications-meta 全部入り（約4GB）") CONFIG[kde_apps]="full" ;;
    esac
    print_ok "KDE アプリ規模: ${CONFIG[kde_apps]}"
  else
    CONFIG[kde_apps]="none"
  fi

  print_ok "デスクトップ: ${CONFIG[desktop]}"

  # DE が none の場合は DM 不要
  [[ "${CONFIG[desktop]}" == "none" ]] && { CONFIG[dm]="none"; return; }

  echo ""

  # DE ごとに対応 DM と推奨を変える
  local dm=""
  case "${CONFIG[desktop]}" in
    kde)
      local dm
      dm=$(select_from_list "ディスプレイマネージャー (DM) を選択:" \
        "SDDM       - KDE 推奨・Wayland/X11（推奨）" \
        "GDM        - GNOME 製・Wayland 対応" \
        "LightDM    - 軽量・X11/Wayland" \
        "greetd     - 最軽量・TUI" \
        "なし       - TTY から手動起動")
      ;;
    gnome|budgie)
      local dm
      dm=$(select_from_list "ディスプレイマネージャー (DM) を選択:" \
        "GDM        - GNOME 推奨・Wayland 対応（推奨）" \
        "SDDM       - 軽量・Wayland/X11" \
        "LightDM    - 軽量・X11/Wayland" \
        "greetd     - 最軽量・TUI" \
        "なし       - TTY から手動起動")
      ;;
    xfce)
      local dm
      dm=$(select_from_list "ディスプレイマネージャー (DM) を選択:" \
        "LightDM    - Xfce 推奨・軽量（推奨）" \
        "SDDM       - 軽量・Wayland/X11" \
        "GDM        - GNOME 製・Wayland 対応" \
        "greetd     - 最軽量・TUI" \
        "なし       - TTY から手動起動")
      ;;
    cosmic)
      local dm
      dm=$(select_from_list "ディスプレイマネージャー (DM) を選択:" \
        "cosmic-greeter - COSMIC 専用グリーター（推奨）" \
        "GDM            - GNOME 製・Wayland 対応" \
        "SDDM           - 軽量・Wayland/X11" \
        "greetd         - 最軽量・TUI" \
        "なし           - TTY から手動起動")
      ;;
    sway|hyprland|niri)
      local dm
      dm=$(select_from_list "ディスプレイマネージャー (DM) を選択:" \
        "greetd     - 最軽量・TUI（推奨）" \
        "SDDM       - GUI・Wayland/X11" \
        "GDM        - GNOME 製・Wayland 対応" \
        "なし       - TTY から手動起動")
      ;;
  esac

  case "$dm" in
    SDDM*|"SDDM           - 軽量・Wayland/X11")    CONFIG[dm]="sddm" ;;
    GDM*)                                            CONFIG[dm]="gdm" ;;
    LightDM*)                                        CONFIG[dm]="lightdm" ;;
    "cosmic-greeter"*)                               CONFIG[dm]="cosmic-greeter" ;;
    greetd*)                                         CONFIG[dm]="greetd" ;;
    "なし"*)                                         CONFIG[dm]="none" ;;
    # fallback: 先頭単語で判定
    *)
      case "${dm%% *}" in
        SDDM)          CONFIG[dm]="sddm" ;;
        GDM)           CONFIG[dm]="gdm" ;;
        LightDM)       CONFIG[dm]="lightdm" ;;
        cosmic-greeter) CONFIG[dm]="cosmic-greeter" ;;
        greetd)        CONFIG[dm]="greetd" ;;
        *)             CONFIG[dm]="none" ;;
      esac
      ;;
  esac

  print_ok "DM: ${CONFIG[dm]}"
}

# ============================================
# ステップ: フォント選択
# ============================================

step_fonts() {
  print_step "フォント設定"

  CONFIG[font_pkgs]=""
  CONFIG[font_setup_fontconfig]="no"

  echo -e "  インストールするフォントを選択してください。\n"

  # ── Fira ──────────────────────────────────
  echo -e "  ${CYAN}${BOLD}[ Fira フォントファミリー ]${RESET}"
  local fira_pkgs=()
  if confirm "Fira Code をインストールしますか？（等幅・プログラミング用リガチャ）"; then
    fira_pkgs+=(ttf-fira-code);  print_ok "ttf-fira-code"
  fi
  if confirm "Fira Sans をインストールしますか？（サンセリフ・UI 向け）"; then
    fira_pkgs+=(ttf-fira-sans);  print_ok "ttf-fira-sans"
  fi
  if confirm "Fira Mono をインストールしますか？（等幅・リガチャなし）"; then
    fira_pkgs+=(ttf-fira-mono);  print_ok "ttf-fira-mono"
  fi

  # ── Emoji ─────────────────────────────────
  echo ""
  echo -e "  ${CYAN}${BOLD}[ 絵文字フォント ]${RESET}"
  local emoji_pkgs=()
  local emoji_choice
  emoji_choice=$(select_from_list "絵文字フォントを選択:" \
    "Noto Color Emoji  - Google 製・カラー絵文字（推奨）" \
    "Noto Emoji        - モノクロ版（軽量）" \
    "両方インストール" \
    "インストールしない")
  case "$emoji_choice" in
    "Noto Color Emoji  - Google 製・カラー絵文字（推奨）")
      emoji_pkgs+=(noto-fonts-emoji);                        print_ok "noto-fonts-emoji" ;;
    "Noto Emoji        - モノクロ版（軽量）")
      emoji_pkgs+=(noto-fonts);                              print_ok "noto-fonts" ;;
    "両方インストール")
      emoji_pkgs+=(noto-fonts-emoji noto-fonts);             print_ok "noto-fonts-emoji + noto-fonts" ;;
    *) print_ok "絵文字フォントはスキップ" ;;
  esac

  # ── 日本語フォント ─────────────────────────
  echo ""
  echo -e "  ${CYAN}${BOLD}[ 日本語フォント ]${RESET}"
  local jp_pkgs=()
  local jp_choice
  jp_choice=$(select_from_list "日本語フォントを選択:" \
    "Noto Sans/Serif CJK       - Google 製・網羅的（推奨）" \
    "源ノ角ゴシック (Source Han Sans)  - Adobe 製・高品質ゴシック" \
    "源ノ明朝 (Source Han Serif)       - Adobe 製・高品質明朝" \
    "ゴシック＋明朝（Source Han 両方）" \
    "Noto CJK＋Source Han 全部" \
    "インストールしない")
  case "$jp_choice" in
    "Noto Sans/Serif CJK       - Google 製・網羅的（推奨）")
      jp_pkgs+=(noto-fonts noto-fonts-cjk)
      print_ok "noto-fonts + noto-fonts-cjk" ;;
    "源ノ角ゴシック (Source Han Sans)  - Adobe 製・高品質ゴシック")
      jp_pkgs+=(adobe-source-han-sans-jp-fonts)
      print_ok "adobe-source-han-sans-jp-fonts" ;;
    "源ノ明朝 (Source Han Serif)       - Adobe 製・高品質明朝")
      jp_pkgs+=(adobe-source-han-serif-jp-fonts)
      print_ok "adobe-source-han-serif-jp-fonts" ;;
    "ゴシック＋明朝（Source Han 両方）")
      jp_pkgs+=(adobe-source-han-sans-jp-fonts adobe-source-han-serif-jp-fonts)
      print_ok "源ノ角ゴシック + 源ノ明朝" ;;
    "Noto CJK＋Source Han 全部")
      jp_pkgs+=(noto-fonts noto-fonts-cjk
                adobe-source-han-sans-jp-fonts adobe-source-han-serif-jp-fonts)
      print_ok "Noto CJK + 源ノ角ゴシック + 源ノ明朝" ;;
    *) print_ok "日本語フォントはスキップ" ;;
  esac

  # ── まとめ ────────────────────────────────
  local all_pkgs=("${fira_pkgs[@]}" "${emoji_pkgs[@]}" "${jp_pkgs[@]}")
  if [[ ${#all_pkgs[@]} -gt 0 ]]; then
    CONFIG[font_pkgs]="${all_pkgs[*]}"
    # Emoji と日本語が共存する場合は fontconfig 優先度を自動設定
    if [[ ${#emoji_pkgs[@]} -gt 0 && ${#jp_pkgs[@]} -gt 0 ]]; then
      CONFIG[font_setup_fontconfig]="yes"
      print_ok "fontconfig: 絵文字・日本語の優先度を自動設定します"
    fi
    echo ""
    print_ok "インストール予定: ${CONFIG[font_pkgs]}"
  else
    print_ok "フォントのインストールはスキップしました"
  fi
}

# ============================================
# ステップ 7: 追加パッケージ
# ============================================

step_extra_packages() {

  echo -e "  ${YELLOW}※ base-devel はデフォルトでインストールされません。${RESET}"
  echo -e "  ${YELLOW}  AUR（yay/paru）や自前ビルドが必要な場合のみ追加してください。${RESET}\n"

  CONFIG[extra_base_devel]="no"
  CONFIG[extra_zram]="no"
  CONFIG[extra_pkgs]=""

  if confirm "base-devel を追加しますか？（gcc, make, binutils など AUR に必要）"; then
    CONFIG[extra_base_devel]="yes"
    print_ok "base-devel を追加"
  else
    print_ok "base-devel はスキップ（後から: pacman -S base-devel）"
  fi

  if confirm "zram を有効にしますか？（RAM 上の圧縮 swap・推奨）"; then
    CONFIG[extra_zram]="yes"
    print_ok "zram-generator を追加"
  fi

  CONFIG[aur_helper]="none"
  if [[ "${CONFIG[extra_base_devel]}" == "yes" ]]; then
    if confirm "AUR ヘルパー（yay / paru）をインストールしますか？"; then
      local helper
      helper=$(select_from_list "インストールする AUR ヘルパーを選択してください:" \
        "yay  - Go製・人気No.1（バイナリ版をビルドしてインストール）" \
        "paru - Rust製・高機能・高速")
      case "$helper" in
        "yay"*)  CONFIG[aur_helper]="yay" ;;
        "paru"*) CONFIG[aur_helper]="paru" ;;
      esac
      print_ok "AUR ヘルパー: ${CONFIG[aur_helper]}"
    fi
  fi

  CONFIG[extra_ssh]="no"
  if confirm "OpenSSH サーバーをインストールして有効化しますか？"; then
    CONFIG[extra_ssh]="yes"
    print_ok "OpenSSH をインストール"
  fi

  CONFIG[extra_ufw]="no"
  if confirm "ufw（ファイアウォール）をインストールして有効化しますか？"; then
    CONFIG[extra_ufw]="yes"
    print_ok "ufw をインストール"
  fi

  local extra
  extra=$(ask "その他追加パッケージ（スペース区切り、不要なら空 Enter）" "")
  CONFIG[extra_pkgs]="$extra"
  [[ -n "$extra" ]] && print_ok "追加パッケージ: $extra"
}

# ============================================
# 設定サマリー表示
# ============================================

show_summary() {
  print_header
  print_step "インストール設定サマリー"

  echo -e "  ${BOLD}ディスク      :${RESET} ${CONFIG[disk]}"
  echo -e "  ${BOLD}パーティション :${RESET} ${CONFIG[partition_scheme]}"
  echo -e "  ${BOLD}ホスト名      :${RESET} ${CONFIG[hostname]}"
  echo -e "  ${BOLD}タイムゾーン  :${RESET} ${CONFIG[timezone]}"
  echo -e "  ${BOLD}RTC モード    :${RESET} $([[ "${CONFIG[dualboot_windows]:-no}" == "yes" ]] && echo "localtime（Windows 共存）" || echo "UTC（推奨）")"
  echo -e "  ${BOLD}ロケール      :${RESET} ${CONFIG[locale]}"
  echo -e "  ${BOLD}キーマップ    :${RESET} ${CONFIG[keymap]}"
  if [[ "${CONFIG[japanese_env]}" == "yes" ]]; then
    echo -e "  ${BOLD}IME           :${RESET} ${CONFIG[jp_ime]:-none}"
  fi
  if [[ -n "${CONFIG[font_pkgs]}" ]]; then
    echo -e "  ${BOLD}フォント      :${RESET} ${CONFIG[font_pkgs]}"
  fi
  echo -e "  ${BOLD}ファームウェア :${RESET} ${CONFIG[boot_mode]}"
  echo -e "  ${BOLD}ブートローダー :${RESET} ${CONFIG[bootloader]}"
  echo -e "  ${BOLD}WiFi バックエンド:${RESET} ${CONFIG[wifi_backend]}"
  echo -e "  ${BOLD}systemd-resolved:${RESET} ${CONFIG[use_resolved]}"
  local mirror_disp="${CONFIG[mirror_mode]}"
  [[ "${CONFIG[mirror_mode]}" == "manual" ]] && mirror_disp="manual (${CONFIG[mirror_host]})"
  echo -e "  ${BOLD}ミラー          :${RESET} ${mirror_disp}"
  echo -e "  ${BOLD}デスクトップ  :${RESET} ${CONFIG[desktop]}"
  [[ "${CONFIG[desktop]}" == "kde" ]] && \
    echo -e "  ${BOLD}KDE アプリ規模 :${RESET} ${CONFIG[kde_apps]}"
  echo -e "  ${BOLD}DM            :${RESET} ${CONFIG[dm]:-none}"
  echo -e "  ${BOLD}GPU ドライバ   :${RESET} ${CONFIG[gpu_driver]}"
  echo -e "  ${BOLD}base-devel    :${RESET} ${CONFIG[extra_base_devel]}"
  echo -e "  ${BOLD}AUR ヘルパー   :${RESET} ${CONFIG[aur_helper]}"
  echo -e "  ${BOLD}OpenSSH       :${RESET} ${CONFIG[extra_ssh]}"
  echo -e "  ${BOLD}ufw (FW)      :${RESET} ${CONFIG[extra_ufw]}"
  echo -e "  ${BOLD}zram          :${RESET} ${CONFIG[extra_zram]}"
  if [[ "${CONFIG[virt_env]}" != "none" ]]; then
    echo -e "  ${BOLD}仮想環境      :${RESET} ${CONFIG[virt_env]} (ゲストツール自動有効化)"
  fi
  if [[ "${CONFIG[dry_run]}" == "yes" ]]; then
    echo -e "  ${BOLD}ドライラン    :${RESET} ${RED}有効 (実行はスキップされます)${RESET}"
  fi
  [[ -n "${CONFIG[extra_pkgs]}" ]] && \
    echo -e "  ${BOLD}追加パッケージ :${RESET} ${CONFIG[extra_pkgs]}"
  if [[ "${CONFIG[users_count]:-0}" -gt 0 ]]; then
    echo -e "  ${BOLD}ユーザー      :${RESET}"
    while IFS='|' read -r n _ s sh _; do
      [[ -z "$n" ]] && continue
      echo -e "    ${CYAN}•${RESET} ${n}  sudo: ${s}  shell: ${sh}"
    done <<< "${CONFIG[users]}"
  else
    echo -e "  ${BOLD}ユーザー      :${RESET} root のみ"
  fi

  echo ""
  print_warn "上記の設定でインストールを開始します。"
  print_warn "ディスク ${CONFIG[disk]} の全データが消去されます！"
}

# ============================================
# 実行: パーティション
# ============================================

do_partition() {
  local disk="${CONFIG[disk]}"
  local scheme="${CONFIG[partition_scheme]}"
  local boot_mode="${CONFIG[boot_mode]}"

  print_step "パーティション処理"

  if [[ "$scheme" == "manual" ]]; then
    print_warn "fdisk を起動します。終了後 Enter を押してください。"
    fdisk "$disk"
    return
  fi

  # GPT で全消去
  run_cmd "GPT テーブル作成" sgdisk --zap-all "$disk"
  run_cmd "GPT 初期化" sgdisk --clear "$disk"

  if [[ "$boot_mode" == "uefi" ]]; then
    # EFI パーティション (512MB)
    run_cmd "EFI パーティション作成" \
      sgdisk --new=1:0:+512M --typecode=1:ef00 --change-name=1:EFI "$disk"

    if [[ "$scheme" == "auto_swap" ]]; then
      # swap (4GB)
      run_cmd "swap パーティション作成" \
        sgdisk --new=2:0:+4G --typecode=2:8200 --change-name=2:swap "$disk"
      # root (残り全部)
      run_cmd "root パーティション作成" \
        sgdisk --new=3:0:0 --typecode=3:8300 --change-name=3:root "$disk"
    else
      # root (残り全部)
      run_cmd "root パーティション作成" \
        sgdisk --new=2:0:0 --typecode=2:8300 --change-name=2:root "$disk"
    fi
  else
    # BIOS: BIOS Boot (1MB) + swap + root
    run_cmd "BIOS Boot パーティション作成" \
      sgdisk --new=1:0:+1M --typecode=1:ef02 "$disk"

    if [[ "$scheme" == "auto_swap" ]]; then
      run_cmd "swap パーティション作成" \
        sgdisk --new=2:0:+4G --typecode=2:8200 --change-name=2:swap "$disk"
      run_cmd "root パーティション作成" \
        sgdisk --new=3:0:0 --typecode=3:8300 --change-name=3:root "$disk"
    else
      run_cmd "root パーティション作成" \
        sgdisk --new=2:0:0 --typecode=2:8300 --change-name=2:root "$disk"
    fi
  fi

  # カーネルにパーティションテーブル再読込を通知
  run_cmd "パーティションテーブル再読込" partprobe "$disk"
  sleep 1
}

# ============================================
# 実行: フォーマット & マウント
# ============================================

do_format_and_mount() {
  local disk="${CONFIG[disk]}"
  local scheme="${CONFIG[partition_scheme]}"
  local boot_mode="${CONFIG[boot_mode]}"
  local efi_part="" swap_part="" root_part=""

  print_step "フォーマット & マウント"

  # 手動パーティションの場合はユーザーが自分でマウントするか、アシスタントを使う
  if [[ "$scheme" == "manual" ]]; then
    echo ""
    print_warn "手動パーティションモードです。"

    local mount_method
    mount_method=$(select_from_list "マウント方法を選択してください:" \
      "対話型アシスタントを使用（推奨・スクリプト内でマウントを指定）" \
      "手動でマウントする（別ターミナルなどでマウント済みの状態にする）")

    if [[ "$mount_method" == "対話型アシスタントを使用（推奨・スクリプト内でマウントを指定）" ]]; then
      echo ""
      print_warn "検出されたパーティション一覧:"
      lsblk -p "$disk"
      echo ""

      local root_p=""
      while true; do
        root_p=$(ask "Root (/) パーティションのデバイスパスを指定してください (例: /dev/sda2)")
        if [[ -b "$root_p" ]]; then
          break
        fi
        print_err "有効なブロックデバイスではありません: $root_p"
      done

      if confirm "Root パーティション ($root_p) を ext4 でフォーマットしますか？（※既存データは消去されます）"; then
        run_cmd "root フォーマット (ext4)" mkfs.ext4 -F "$root_p"
      fi
      run_cmd "root マウント" mount "$root_p" /mnt

      # UEFI の場合
      if [[ "$boot_mode" == "uefi" ]]; then
        local efi_p=""
        while true; do
          efi_p=$(ask "EFI パーティションのデバイスパスを指定してください (例: /dev/sda1)")
          if [[ -b "$efi_p" ]]; then
            break
          fi
          print_err "有効なブロックデバイスではありません: $efi_p"
        done

        if confirm "EFI パーティション ($efi_p) を FAT32 でフォーマットしますか？"; then
          run_cmd "EFI フォーマット (FAT32)" mkfs.fat -F32 "$efi_p"
        fi
        run_cmd "EFI ディレクトリ作成" mkdir -p /mnt/boot
        run_cmd "EFI マウント" mount "$efi_p" /mnt/boot
      fi

      # Swap
      local swap_p=""
      swap_p=$(ask "Swap パーティションのデバイスパスを指定してください（不要なら空 Enter）" "")
      if [[ -n "$swap_p" ]]; then
        if [[ -b "$swap_p" ]]; then
          if confirm "Swap パーティション ($swap_p) をフォーマットして有効化しますか？"; then
            run_cmd "swap フォーマット" mkswap "$swap_p"
          fi
          run_cmd "swap 有効化" swapon "$swap_p"
        else
          print_warn "有効なデバイスではないため swap はスキップされました: $swap_p"
        fi
      fi
    else
      # 従来の手動マウントガイド
      echo -e "  インストール先のパーティションを手動でマウントしてください。\n"
      echo -e "  ${BOLD}例（UEFI・/dev/sda の場合）:${RESET}"
      echo -e "    mount /dev/sda2 /mnt"
      echo -e "    mkdir -p /mnt/boot"
      echo -e "    mount /dev/sda1 /mnt/boot   # EFI パーティション"
      echo -e "    swapon /dev/sda3            # swap がある場合\n"
      if ! confirm "マウント完了しましたか？"; then
        print_err "中断しました。"
        exit 1
      fi
    fi

    # マウント確認
    if ! mountpoint -q /mnt; then
      print_err "/mnt がマウントされていません。"
      exit 1
    fi
    if [[ "$boot_mode" == "uefi" ]] && ! mountpoint -q /mnt/boot; then
      print_err "/mnt/boot がマウントされていません（UEFI には必須）。"
      exit 1
    fi
    print_ok "マウント確認OK"
    return
  fi

  if [[ "$boot_mode" == "uefi" ]]; then
    efi_part=$(part_suffix "$disk" 1)

    if [[ "$scheme" == "auto_swap" ]]; then
      swap_part=$(part_suffix "$disk" 2)
      root_part=$(part_suffix "$disk" 3)
    else
      root_part=$(part_suffix "$disk" 2)
    fi

    run_cmd "EFI フォーマット (FAT32)"  mkfs.fat -F32 "$efi_part"
    run_cmd "root フォーマット (ext4)"  mkfs.ext4 -F "$root_part"
    [[ -n "$swap_part" ]] && run_cmd "swap フォーマット" mkswap "$swap_part"

    run_cmd "root マウント"   mount "$root_part" /mnt
    run_cmd "EFI ディレクトリ作成" mkdir -p /mnt/boot
    run_cmd "EFI マウント"    mount "$efi_part" /mnt/boot
    [[ -n "$swap_part" ]] && run_cmd "swap 有効化" swapon "$swap_part"

  else
    # BIOS
    local root_part swap_part=""
    if [[ "$scheme" == "auto_swap" ]]; then
      swap_part=$(part_suffix "$disk" 2)
      root_part=$(part_suffix "$disk" 3)
    else
      root_part=$(part_suffix "$disk" 2)
    fi

    run_cmd "root フォーマット (ext4)" mkfs.ext4 -F "$root_part"
    [[ -n "$swap_part" ]] && run_cmd "swap フォーマット" mkswap "$swap_part"

    run_cmd "root マウント" mount "$root_part" /mnt
    [[ -n "$swap_part" ]] && run_cmd "swap 有効化" swapon "$swap_part"
  fi
}

# ============================================
# ネットワーク疎通確認
# ============================================

check_network() {
  print_step "ネットワーク確認"
  echo -ne "  ${CYAN}…${RESET} インターネット接続を確認中..."
  if ping -c1 -W3 archlinux.org &>/dev/null; then
    echo -e "\r  ${GREEN}✔${RESET} インターネット接続OK"
  else
    echo -e "\r  ${RED}✘${RESET} インターネットに接続できません"
    echo ""
    print_warn "有線接続の場合: ケーブルを確認してください"
    print_warn "WiFi の場合  : iwctl で接続してください"
    echo -e "\n  ${BOLD}iwctl の使い方:${RESET}"
    echo "    iwctl"
    echo "    [iwd]# device list"
    echo "    [iwd]# station wlan0 scan"
    echo "    [iwd]# station wlan0 get-networks"
    echo "    [iwd]# station wlan0 connect <SSID>"
    echo ""
    if ! confirm "接続できました。続けますか？"; then
      print_err "中断しました。"
      exit 1
    fi
    # 再確認
    echo -ne "  ${CYAN}…${RESET} 再確認中..."
    if ping -c1 -W5 archlinux.org &>/dev/null; then
      echo -e "\r  ${GREEN}✔${RESET} インターネット接続OK"
    else
      echo -e "\r  ${RED}✘${RESET} まだ接続できません。終了します。"
      exit 1
    fi
  fi

  # Live ISO の時刻を NTP で同期
  # （狂ったままだと pacman の署名検証が失敗することがある）
  echo -ne "  ${CYAN}…${RESET} NTP 時刻同期中..."
  timedatectl set-ntp true
  # 最大10秒待って同期を確認
  local i
  for i in {1..10}; do
    if timedatectl status 2>/dev/null | grep -q "synchronized: yes"; then
      echo -e "\r  ${GREEN}✔${RESET} NTP 時刻同期完了: $(date '+%Y-%m-%d %H:%M:%S %Z')"
      return
    fi
    sleep 1
  done
  echo -e "\r  ${YELLOW}⚠${RESET} NTP 同期タイムアウト（続行します）"
  echo -e "    現在時刻: $(date '+%Y-%m-%d %H:%M:%S %Z')"
}

# ============================================
# ステップ: ネットワーク設定（インストール後）
# ============================================

step_network() {
  print_step "ネットワーク設定"

  # WiFi バックエンド選択
  local wifi_backend
  wifi_backend=$(select_from_list "WiFi バックエンドを選択:" \
    "wpa_supplicant（枯れた実装・互換性重視）" \
    "iwd（モダン・高速・推奨）" \
    "なし（有線のみ・後から設定）")

  case "$wifi_backend" in
    "wpa_supplicant（枯れた実装・互換性重視）") CONFIG[wifi_backend]="wpa_supplicant" ;;
    "iwd（モダン・高速・推奨）")                 CONFIG[wifi_backend]="iwd" ;;
    "なし（有線のみ・後から設定）")              CONFIG[wifi_backend]="none" ;;
  esac
  print_ok "WiFi バックエンド: ${CONFIG[wifi_backend]}"

  # systemd-resolved 使用確認
  if confirm "systemd-resolved を使いますか？（DNS キャッシュ・DNSSEC・推奨）"; then
    CONFIG[use_resolved]="yes"
    print_ok "systemd-resolved を有効化します"
  else
    CONFIG[use_resolved]="no"
    print_ok "systemd-resolved はスキップ（NetworkManager がDNSを直接管理）"
  fi
}

# ============================================
# ステップ: ミラーサーバー設定
# ============================================

step_mirror() {
  print_step "ミラーサーバー設定"

  local country
  country=$(get_mirror_country)
  local country_disp="${country:-全世界}"

  local choice
  choice=$(select_from_list "ミラーサーバーの選択方法:" \
    "自動（reflector で ${country_disp} の速いミラーを自動選択・推奨）" \
    "自動（国を手動で指定して reflector を実行）" \
    "日本のミラーを手動で選ぶ（日本国内向け）" \
    "現在の設定をそのまま使う")

  case "$choice" in
    "自動（reflector で ${country_disp} の速いミラーを自動選択・推奨）")
      CONFIG[mirror_mode]="auto"
      CONFIG[mirror_country]="$country"
      print_ok "reflector で ${country_disp} のミラーを自動選択します"
      ;;
    "自動（国を手動で指定して reflector を実行）")
      CONFIG[mirror_mode]="auto"
      local custom_country
      custom_country=$(ask "reflector で使用する国名（英語名、例: Japan, United States, Germany。カンマ区切りで複数可）" "Japan")
      CONFIG[mirror_country]="$custom_country"
      print_ok "reflector で ${custom_country} のミラーを自動選択します"
      ;;
    "日本のミラーを手動で選ぶ（日本国内向け）")
      CONFIG[mirror_mode]="manual"
      echo ""
      local mirrors=(
        "ftp.jaist.ac.jp        - JAIST（北陸先端科学技術大学院大学）"
        "mirrors.cat.net        - CATネット（京都）"
        "ftp.tsukuba.wide.ad.jp - WIDE Project（筑波）"
        "mirror.archlinux.jp    - Arch Linux Japan 公式"
        "repo.jing.rocks        - Jing（東京）"
      )
      local selected
      selected=$(select_from_list "使用するミラーを選択:" "${mirrors[@]}")
      CONFIG[mirror_host]=$(echo "$selected" | awk '{print $1}')
      print_ok "ミラー: ${CONFIG[mirror_host]}"
      ;;
    "現在の設定をそのまま使う")
      CONFIG[mirror_mode]="keep"
      print_ok "現在の mirrorlist を使用します"
      ;;
  esac
}

# ============================================
# 実行: ミラーリスト設定
# ============================================

do_mirrorlist() {
  print_step "ミラーリスト設定"

  case "${CONFIG[mirror_mode]}" in
    auto)
      # reflector が入っていなければインストール
      if ! command -v reflector &>/dev/null; then
        run_cmd "reflector インストール" pacman -S --noconfirm reflector
      fi

      local country_opt=""
      if [[ -n "${CONFIG[mirror_country]:-}" ]]; then
        country_opt="--country ${CONFIG[mirror_country]}"
      fi

      local country_disp="${CONFIG[mirror_country]:-全世界}"
      # 指定のミラーから HTTPS・最終同期24時間以内・速度順 上位8件
      run_cmd "reflector 実行（${country_disp}・速度順）" \
        reflector \
          ${country_opt} \
          --protocol https \
          --age 24 \
          --sort rate \
          --number 8 \
          --save /etc/pacman.d/mirrorlist
      print_ok "選択されたミラー:"
      grep '^Server' /etc/pacman.d/mirrorlist | sed 's/^/    /'
      ;;

    manual)
      local host="${CONFIG[mirror_host]}"
      run_cmd "ミラーリスト書き込み" bash -c "cat > /etc/pacman.d/mirrorlist << EOF
# 手動選択: ${host}
Server = https://${host}/archlinux/\\\$repo/os/\\\$arch
Server = http://${host}/archlinux/\\\$repo/os/\\\$arch
EOF"
      print_ok "ミラー: ${host}"
      ;;

    keep)
      print_ok "既存の mirrorlist をそのまま使用"
      ;;
  esac
}

# ============================================
# 実行: ベースインストール
# ============================================

do_pacstrap() {
  print_step "ベースシステムのインストール"

  # pacman キーリング初期化（署名検証に必要）
  run_cmd "pacman キーリング初期化" pacman-key --init
  run_cmd "Arch キーリング追加"    pacman-key --populate archlinux
  # パッケージデータベースを最新に
  run_cmd "パッケージDB更新" pacman -Sy --noconfirm

  local pkgs=(base sudo linux linux-firmware networkmanager vim)

  # WiFi バックエンド
  case "${CONFIG[wifi_backend]}" in
    wpa_supplicant) pkgs+=(wpa_supplicant) ;;
    iwd)            pkgs+=(iwd) ;;
  esac

  # systemd-resolved
  # （パッケージは systemd に含まれるが、明示的に記録）

  # マイクロコード
  local cpu_vendor
  cpu_vendor=$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $3}')
  if [[ "$cpu_vendor" == "GenuineIntel" ]]; then
    pkgs+=(intel-ucode)
    print_ok "Intel マイクロコードを追加"
  elif [[ "$cpu_vendor" == "AuthenticAMD" ]]; then
    pkgs+=(amd-ucode)
    print_ok "AMD マイクロコードを追加"
  fi

  # ユーザーのログインシェル（zsh / fish）を自動追加
  if [[ "${CONFIG[users]:-}" =~ \|zsh\| ]]; then
    pkgs+=(zsh)
    print_ok "ログインシェル用 zsh を追加"
  fi
  if [[ "${CONFIG[users]:-}" =~ \|fish\| ]]; then
    pkgs+=(fish)
    print_ok "ログインシェル用 fish を追加"
  fi

  # GRUB 選択時は追加パッケージ
  if [[ "${CONFIG[bootloader]}" == "grub" ]]; then
    pkgs+=(grub)
    if [[ "${CONFIG[boot_mode]}" == "uefi" ]]; then
      pkgs+=(efibootmgr)
    fi
  fi

  # AURヘルパー用 git の追加
  if [[ "${CONFIG[aur_helper]}" != "none" ]]; then
    pkgs+=(git)
  fi

  # OpenSSH, UFW の追加
  [[ "${CONFIG[extra_ssh]}" == "yes" ]] && pkgs+=(openssh)
  [[ "${CONFIG[extra_ufw]}" == "yes" ]] && pkgs+=(ufw)

  # GPU ドライバーの追加
  case "${CONFIG[gpu_driver]}" in
    nvidia)  pkgs+=(nvidia nvidia-utils) ;;
    nouveau) pkgs+=(xf86-video-nouveau mesa) ;;
    amdgpu)  pkgs+=(xf86-video-amdgpu mesa vulkan-radeon) ;;
    intel)   pkgs+=(xf86-video-intel mesa vulkan-intel) ;;
    virtual) pkgs+=(xf86-video-vmware) ;;
  esac

  # 仮想環境ゲストツールの追加
  case "${CONFIG[virt_env]}" in
    oracle)             pkgs+=(virtualbox-guest-utils) ;;
    kvm|qemu)           pkgs+=(qemu-guest-agent) ;;
    vmware)             pkgs+=(open-vm-tools) ;;
  esac

  # ユーザーが選択した追加パッケージ
  [[ "${CONFIG[extra_base_devel]}" == "yes" ]] && pkgs+=(base-devel)
  [[ "${CONFIG[extra_zram]}" == "yes" ]]       && pkgs+=(zram-generator)
  if [[ -n "${CONFIG[extra_pkgs]}" ]]; then
    read -ra _extra <<< "${CONFIG[extra_pkgs]}"
    pkgs+=("${_extra[@]}")
  fi

  # フォント
  if [[ -n "${CONFIG[font_pkgs]}" ]]; then
    read -ra _font_pkgs <<< "${CONFIG[font_pkgs]}"
    pkgs+=("${_font_pkgs[@]}")
  fi

  # IME
  case "${CONFIG[jp_ime]}" in
    fcitx5-mozc)
      pkgs+=(fcitx5 fcitx5-mozc fcitx5-gtk fcitx5-qt fcitx5-configtool) ;;
    fcitx5-anthy)
      pkgs+=(fcitx5 fcitx5-anthy fcitx5-gtk fcitx5-qt fcitx5-configtool) ;;
    ibus-mozc)
      pkgs+=(ibus ibus-mozc) ;;
  esac

  run_cmd "pacstrap 実行（時間がかかります）" pacstrap /mnt "${pkgs[@]}"
}
do_fstab() {
  print_step "fstab 生成"
  run_cmd "fstab 生成" bash -c "genfstab -U /mnt >> /mnt/etc/fstab"
  print_ok "生成内容:"
  cat /mnt/etc/fstab | sed 's/^/    /'
}

# ============================================
# 実行: chroot 内設定
# ============================================

do_chroot_config() {
  print_step "chroot 内設定"

  # タイムゾーン・時刻設定
  run_cmd "タイムゾーン設定" \
    arch-chroot /mnt ln -sf "/usr/share/zoneinfo/${CONFIG[timezone]}" /etc/localtime

  if [[ "${CONFIG[dualboot_windows]:-no}" == "yes" ]]; then
    # Windows と共存: RTC をローカル時刻として扱う
    # timedatectl は chroot 内で動かないため /etc/adjtime を直接書く
    run_cmd "RTC ローカル時刻設定（Windows 互換）" \
      arch-chroot /mnt hwclock --systohc --localtime
    run_cmd "adjtime LOCAL 設定" bash -c \
      "sed -i 's/^UTC$/LOCAL/' /mnt/etc/adjtime 2>/dev/null || \
       printf 'LOCAL\n0\n0\n' >> /mnt/etc/adjtime"
  else
    # 通常: RTC を UTC として扱う（推奨）
    run_cmd "RTC UTC 設定" arch-chroot /mnt hwclock --systohc --utc
  fi

  # systemd-timesyncd を有効化（インストール後も NTP 同期を維持）
  run_cmd "systemd-timesyncd 有効化" \
    arch-chroot /mnt systemctl enable systemd-timesyncd

  # 日本向け NTP サーバーを設定
  if [[ "${CONFIG[timezone]}" == Asia/Tokyo* || "${CONFIG[timezone]}" == Asia/Osaka* ]]; then
    run_cmd "NTP サーバー設定（日本）" bash -c "mkdir -p /mnt/etc/systemd && \
      cat > /mnt/etc/systemd/timesyncd.conf << 'EOF'
[Time]
NTP=ntp.nict.go.jp 0.jp.pool.ntp.org 1.jp.pool.ntp.org
FallbackNTP=0.arch.pool.ntp.org 1.arch.pool.ntp.org
EOF"
    print_ok "NTP: nict.go.jp（国立研究開発法人情報通信研究機構）"
  else
    run_cmd "NTP サーバー設定（デフォルト）" bash -c "mkdir -p /mnt/etc/systemd && \
      cat > /mnt/etc/systemd/timesyncd.conf << 'EOF'
[Time]
NTP=0.arch.pool.ntp.org 1.arch.pool.ntp.org 2.arch.pool.ntp.org
FallbackNTP=0.pool.ntp.org 1.pool.ntp.org
EOF"
  fi

  # ロケール（sed のパターンで . をエスケープして誤マッチを防ぐ）
  local locale_escaped="${CONFIG[locale]//./\\.}"
  run_cmd "locale.gen 編集" \
    bash -c "sed -i 's/^#${locale_escaped}/${CONFIG[locale]}/' /mnt/etc/locale.gen"
  # en_US.UTF-8 は常に有効にしておく（一部ツールに必要）
  run_cmd "en_US.UTF-8 有効化" \
    bash -c "sed -i 's/^#en_US\\.UTF-8/en_US.UTF-8/' /mnt/etc/locale.gen"
  run_cmd "locale-gen 実行" arch-chroot /mnt locale-gen
  run_cmd "LANG 設定" \
    bash -c "echo 'LANG=${CONFIG[locale]}' > /mnt/etc/locale.conf"
  run_cmd "キーマップ設定" \
    bash -c "echo 'KEYMAP=${CONFIG[keymap]}' > /mnt/etc/vconsole.conf"

  # ホスト名
  run_cmd "hostname 設定" \
    bash -c "echo '${CONFIG[hostname]}' > /mnt/etc/hostname"
  run_cmd "hosts 設定" bash -c "cat > /mnt/etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${CONFIG[hostname]}.localdomain ${CONFIG[hostname]}
EOF"

  # ネットワーク設定
  run_cmd "NetworkManager 有効化" \
    arch-chroot /mnt systemctl enable NetworkManager

  # WiFi バックエンド設定
  case "${CONFIG[wifi_backend]}" in
    iwd)
      run_cmd "iwd 有効化" arch-chroot /mnt systemctl enable iwd
      # iwd 自体の自動IP取得を無効化（NetworkManager が行うため）
      run_cmd "iwd 設定" bash -c "mkdir -p /mnt/etc/iwd && cat > /mnt/etc/iwd/main.conf << 'EOF'
[General]
EnableNetworkConfiguration=false
EOF"
      # NetworkManager が iwd をバックエンドとして使うよう設定
      run_cmd "NM iwd バックエンド設定" bash -c "mkdir -p /mnt/etc/NetworkManager/conf.d && cat > /mnt/etc/NetworkManager/conf.d/wifi-backend.conf << 'EOF'
[device]
wifi.backend=iwd
EOF"
      print_ok "NetworkManager → iwd バックエンド設定完了"
      ;;
    wpa_supplicant)
      run_cmd "wpa_supplicant 有効化" \
        arch-chroot /mnt systemctl enable wpa_supplicant
      print_ok "NetworkManager → wpa_supplicant バックエンド（デフォルト）"
      ;;
  esac

  # systemd-resolved 設定
  if [[ "${CONFIG[use_resolved]}" == "yes" ]]; then
    run_cmd "systemd-resolved 有効化" \
      arch-chroot /mnt systemctl enable systemd-resolved
    # stub-resolv.conf へのシンボリックリンク
    # NetworkManager が resolved を使うようにする
    run_cmd "resolv.conf シンボリックリンク設定" \
      arch-chroot /mnt ln -sf \
        /run/systemd/resolve/stub-resolv.conf \
        /etc/resolv.conf
    # NetworkManager に resolved を使わせる設定
    run_cmd "NM resolved 連携設定" bash -c "mkdir -p /mnt/etc/NetworkManager/conf.d && cat > /mnt/etc/NetworkManager/conf.d/dns.conf << 'EOF'
[main]
dns=systemd-resolved
EOF"
    print_ok "systemd-resolved + NetworkManager 連携設定完了"
  fi

  # zram 設定
  if [[ "${CONFIG[extra_zram]}" == "yes" ]]; then
    run_cmd "zram 設定ファイル作成" bash -c "cat > /mnt/etc/systemd/zram-generator.conf << EOF
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
EOF"
    print_ok "zram: RAM の最大半分（上限 4GB）を zstd 圧縮で確保"
  fi

  # IME 環境変数（X11 / Wayland で異なる）
  if [[ "${CONFIG[jp_ime]:-none}" != "none" ]]; then
    # デスクトップ環境が Wayland ネイティブかどうか判定
    # Wayland ネイティブ: GNOME(GDM), KDE Plasma, Sway, Hyprland, Niri, COSMIC, Budgie
    # X11 ベース: Xfce など
    local is_wayland="no"
    case "${CONFIG[desktop]}" in
      gnome|kde|sway|hyprland|niri|cosmic|budgie) is_wayland="yes" ;;
    esac

    case "${CONFIG[jp_ime]}" in
      fcitx5-mozc|fcitx5-anthy)
        if [[ "$is_wayland" == "yes" ]]; then
          # Wayland: GTK/QT の IM MODULE は設定しない
          # text-input-v3 プロトコルを DE が処理する
          # XMODIFIERS は XWayland アプリ向けに必要
          run_cmd "fcitx5 環境変数設定 (Wayland)" bash -c "cat >> /mnt/etc/environment << 'EOF'
# fcitx5 - Wayland
# GTK_IM_MODULE / QT_IM_MODULE は意図的に未設定
# (GTK3/4 は text-input-v3、Qt は DE の virtual keyboard を使用)
XMODIFIERS=@im=fcitx
SDL_IM_MODULE=fcitx
EOF"
          # KDE のみ: KWin の仮想キーボードに fcitx5 を設定するメモを残す
          if [[ "${CONFIG[desktop]}" == "kde" ]]; then
            print_warn "KDE: システム設定 → 仮想キーボード → Fcitx5 を選択してください"
          fi
          # Sway: exec で fcitx5 を起動する設定を追加
          if [[ "${CONFIG[desktop]}" == "sway" ]]; then
            run_cmd "Sway: fcitx5 自動起動設定" bash -c "
              mkdir -p /mnt/etc/skel/.config/sway
              echo 'exec fcitx5 -d' >> /mnt/etc/skel/.config/sway/config
            "
          fi
        else
          # X11: GTK_IM_MODULE / QT_IM_MODULE / XMODIFIERS を全て設定
          run_cmd "fcitx5 環境変数設定 (X11)" bash -c "cat >> /mnt/etc/environment << 'EOF'
# fcitx5 - X11
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
SDL_IM_MODULE=fcitx
EOF"
        fi
        ;;
      ibus-mozc)
        if [[ "$is_wayland" == "yes" ]]; then
          run_cmd "ibus 環境変数設定 (Wayland)" bash -c "cat >> /mnt/etc/environment << 'EOF'
# ibus - Wayland
XMODIFIERS=@im=ibus
EOF"
        else
          run_cmd "ibus 環境変数設定 (X11)" bash -c "cat >> /mnt/etc/environment << 'EOF'
# ibus - X11
GTK_IM_MODULE=ibus
QT_IM_MODULE=ibus
XMODIFIERS=@im=ibus
EOF"
        fi
        ;;
    esac

    local mode_label="X11"
    [[ "$is_wayland" == "yes" ]] && mode_label="Wayland"
    print_ok "IME 環境変数設定完了（${mode_label} モード）"
  fi

  # fontconfig 優先度設定（絵文字＋日本語フォントが共存する場合）
  if [[ "${CONFIG[font_setup_fontconfig]:-no}" == "yes" ]]; then
    run_cmd "fontconfig 優先度設定" bash -c "mkdir -p /mnt/etc/fonts/conf.d && \
cat > /mnt/etc/fonts/conf.d/99-custom-fonts.conf << 'EOF'
<?xml version=\"1.0\"?>
<!DOCTYPE fontconfig SYSTEM \"fonts.dtd\">
<fontconfig>
  <!-- 絵文字フォントを最優先（カラー絵文字を他フォントより前に） -->
  <alias>
    <family>emoji</family>
    <prefer>
      <family>Noto Color Emoji</family>
    </prefer>
  </alias>
  <!-- sans-serif の日本語フォント優先順 -->
  <alias>
    <family>sans-serif</family>
    <prefer>
      <family>Noto Sans CJK JP</family>
      <family>Source Han Sans JP</family>
    </prefer>
  </alias>
  <!-- serif の日本語フォント優先順 -->
  <alias>
    <family>serif</family>
    <prefer>
      <family>Noto Serif CJK JP</family>
      <family>Source Han Serif JP</family>
    </prefer>
  </alias>
  <!-- monospace: Fira Code を優先 -->
  <alias>
    <family>monospace</family>
    <prefer>
      <family>Fira Code</family>
      <family>Fira Mono</family>
      <family>Noto Sans Mono CJK JP</family>
    </prefer>
  </alias>
</fontconfig>
EOF"
    print_ok "fontconfig: 絵文字・日本語・Fira の優先度を設定しました"
  fi

  # pacman.conf の最適化
  run_cmd "pacman.conf チューニング（インストール先）" bash -c "
    sed -i 's/^#Color$/Color/' /mnt/etc/pacman.conf
    sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /mnt/etc/pacman.conf
    sed -i '/^#\[multilib\]/,/^#Include = \/etc\/pacman.d\/mirrorlist/s/^#//' /mnt/etc/pacman.conf
  "

  # ハイバネート用の resume フック追加
  if [[ "${CONFIG[partition_scheme]}" == "auto_swap" ]]; then
    run_cmd "mkinitcpio.conf に resume フックを追加" bash -c "
      if grep -q '^HOOKS=' /mnt/etc/mkinitcpio.conf; then
        sed -i 's/\bfilesystems\b/resume filesystems/' /mnt/etc/mkinitcpio.conf
      fi
    "
  fi

  # NVIDIA KMS 設定
  if [[ "${CONFIG[gpu_driver]}" == "nvidia" ]]; then
    run_cmd "mkinitcpio.conf に NVIDIA モジュールを追加" bash -c "
      if grep -q '^MODULES=' /mnt/etc/mkinitcpio.conf; then
        sed -i 's/^MODULES=(\(.*\))/MODULES=(\1 nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /mnt/etc/mkinitcpio.conf
        sed -i 's/MODULES=(\s*/MODULES=(/' /mnt/etc/mkinitcpio.conf
      fi
    "
  fi

  # 各種サービスの有効化
  if [[ "${CONFIG[desktop]}" != "none" ]]; then
    run_cmd "Bluetooth サービス有効化" arch-chroot /mnt systemctl enable bluetooth
  fi

  if [[ "${CONFIG[extra_ssh]}" == "yes" ]]; then
    run_cmd "OpenSSH サービス有効化" arch-chroot /mnt systemctl enable sshd
  fi

  if [[ "${CONFIG[extra_ufw]}" == "yes" ]]; then
    run_cmd "UFW サービス有効化" arch-chroot /mnt systemctl enable ufw
  fi

  case "${CONFIG[virt_env]}" in
    oracle)
      run_cmd "VirtualBox Guest サービス有効化" arch-chroot /mnt systemctl enable vboxservice
      ;;
    kvm|qemu)
      run_cmd "QEMU Guest Agent 有効化" arch-chroot /mnt systemctl enable qemu-guest-agent
      ;;
    vmware)
      run_cmd "VMware Tools サービス有効化" arch-chroot /mnt systemctl enable vmtoolsd
      ;;
  esac

  # xdg-user-dirs-update の自動実行設定（初回ログイン時にホームディレクトリ群を生成）
  run_cmd "初回ログイン時の xdg-user-dirs-update 自動実行設定" bash -c "
    mkdir -p /mnt/etc/skel
    cat >> /mnt/etc/skel/.bash_profile << 'EOF'

# 初回ログイン時にユーザーディレクトリを自動作成
if [ -x /usr/bin/xdg-user-dirs-update ]; then
  xdg-user-dirs-update
fi
EOF
    cat >> /mnt/etc/skel/.zprofile << 'EOF'

# 初回ログイン時にユーザーディレクトリを自動作成
if [ -x /usr/bin/xdg-user-dirs-update ]; then
  xdg-user-dirs-update
fi
EOF
    mkdir -p /mnt/etc/skel/.config/fish
    cat >> /mnt/etc/skel/.config/fish/config.fish << 'EOF'

# 初回ログイン時にユーザーディレクトリを自動作成
if test -x /usr/bin/xdg-user-dirs-update
  xdg-user-dirs-update
end
EOF
  "

  # initramfs の再生成
  run_cmd "initramfs 再生成 (mkinitcpio)" arch-chroot /mnt mkinitcpio -P
}

# ============================================
# 実行: ユーザー設定
# ============================================

do_users() {
  print_step "ユーザー設定"

  # パスワード設定ヘルパー（特殊文字対応）
  _set_password() {
    local user="$1"
    local pw="$2"
    local tmpfile
    tmpfile=$(mktemp)
    printf "%s:%s" "$user" "$pw" > "$tmpfile"
    arch-chroot /mnt chpasswd < "$tmpfile"
    rm -f "$tmpfile"
  }

  local entry
  local ushell usudo uname upw ugroups
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    uname=$(echo "$entry" | cut -d'|' -f1)
    upw=$(echo "$entry" | cut -d'|' -f2)
    usudo=$(echo "$entry" | cut -d'|' -f3)
    ushell=$(echo "$entry" | cut -d'|' -f4)
    ugroups=$(echo "$entry" | cut -d'|' -f5)

    local shell_path="/bin/bash"
    case "$ushell" in
      zsh)  shell_path="/bin/zsh" ;;
      fish) shell_path="/bin/fish" ;;
    esac

    run_cmd "ユーザー作成: ${uname}" \
      arch-chroot /mnt useradd -m -G "$ugroups" -s "$shell_path" "$uname"

    _set_password "$uname" "$upw"

    if [[ "$usudo" == "yes" ]]; then
      run_cmd "sudo 設定: ${uname}" bash -c "
        echo '${uname} ALL=(ALL:ALL) ALL' > /mnt/etc/sudoers.d/${uname}
        chmod 0440 /mnt/etc/sudoers.d/${uname}
      "
    elif [[ "$usudo" == "nopasswd" ]]; then
      run_cmd "sudo 設定: ${uname} (NOPASSWD)" bash -c "
        echo '${uname} ALL=(ALL:ALL) NOPASSWD: ALL' > /mnt/etc/sudoers.d/${uname}
        chmod 0440 /mnt/etc/sudoers.d/${uname}
      "
    fi
  done <<< "${CONFIG[users]}"

  # root パスワード
  if [[ -n "${CONFIG[root_password]}" ]]; then
    _set_password "root" "${CONFIG[root_password]}"
    print_ok "root パスワードを設定しました。"
  else
    print_warn "一般ユーザーが追加されていません。root アカウントのみ作成します。"
  fi
}
do_bootloader() {
  print_step "ブートローダーのインストール"

  local disk="${CONFIG[disk]}"
  local scheme="${CONFIG[partition_scheme]}"
  local root_part
  local swap_part=""
  local swap_partuuid=""

  if [[ "$scheme" == "auto_swap" ]]; then
    swap_part=$(part_suffix "$disk" 2)
    root_part=$(part_suffix "$disk" 3)
  else
    root_part=$(part_suffix "$disk" 2)
  fi

  # swap_partuuid 取得
  if [[ "$scheme" == "auto_swap" ]]; then
    if [[ "${CONFIG[dry_run]}" != "yes" ]]; then
      swap_partuuid=$(blkid -s PARTUUID -o value "$swap_part" || echo "")
    else
      swap_partuuid="DRY-RUN-SWAP-PARTUUID"
    fi
  fi

  # 追加ブートオプション作成
  local extra_options=""
  if [[ -n "$swap_partuuid" ]]; then
    extra_options+=" resume=PARTUUID=${swap_partuuid}"
  fi
  if [[ "${CONFIG[gpu_driver]}" == "nvidia" ]]; then
    extra_options+=" nvidia-drm.modeset=1"
  fi

  if [[ "${CONFIG[bootloader]}" == "systemd-boot" ]]; then
    # bootctl インストール
    run_cmd "bootctl インストール" arch-chroot /mnt bootctl install

    # ローダー設定
    run_cmd "loader.conf 作成" bash -c "cat > /mnt/boot/loader/loader.conf << EOF
default  arch.conf
timeout  5
console-mode max
editor   no
EOF"

    # BIOS モードでは PARTUUID ではなく UUID を使う
    if [[ "${CONFIG[boot_mode]}" != "uefi" ]]; then
      print_warn "BIOS モードでは systemd-boot は使用できません（設定ミス）"
      return 1
    fi

    local root_partuuid
    if [[ "${CONFIG[dry_run]}" != "yes" ]]; then
      root_partuuid=$(blkid -s PARTUUID -o value "$root_part")
    else
      root_partuuid="DRY-RUN-ROOT-PARTUUID"
    fi

    # マイクロコードの initrd を判定
    local ucode_initrd=""
    local cpu_vendor
    cpu_vendor=$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $3}')
    if [[ "$cpu_vendor" == "GenuineIntel" ]]; then
      ucode_initrd="initrd  /intel-ucode.img"
    elif [[ "$cpu_vendor" == "AuthenticAMD" ]]; then
      ucode_initrd="initrd  /amd-ucode.img"
    fi

    # エントリファイル作成（ucode が空の場合は空行を入れない）
    local ucode_line=""
    [[ -n "$ucode_initrd" ]] && ucode_line="${ucode_initrd}"$'\n'
    run_cmd "arch.conf エントリ作成" bash -c "mkdir -p /mnt/boot/loader/entries && cat > /mnt/boot/loader/entries/arch.conf << EOF
title   Arch Linux
linux   /vmlinuz-linux
${ucode_line}initrd  /initramfs-linux.img
options root=PARTUUID=${root_partuuid} rw quiet${extra_options}
EOF"

    # フォールバックエントリ
    run_cmd "arch-fallback.conf 作成" bash -c "cat > /mnt/boot/loader/entries/arch-fallback.conf << EOF
title   Arch Linux (fallback)
linux   /vmlinuz-linux
${ucode_line}initrd  /initramfs-linux-fallback.img
options root=PARTUUID=${root_partuuid} rw${extra_options}
EOF"

    # pacman フック（カーネル更新時に自動更新）
    run_cmd "systemd-boot 自動更新フック設定" \
      arch-chroot /mnt systemctl enable systemd-boot-update.service

  else
    # GRUB
    if [[ "${CONFIG[boot_mode]}" == "uefi" ]]; then
      run_cmd "GRUB インストール (UEFI)" \
        arch-chroot /mnt grub-install \
          --target=x86_64-efi \
          --efi-directory=/boot \
          --bootloader-id=GRUB
    else
      run_cmd "GRUB インストール (BIOS)" \
        arch-chroot /mnt grub-install \
          --target=i386-pc \
          "${CONFIG[disk]}"
    fi

    # GRUB 向けに追加パラメータを設定
    if [[ -n "$extra_options" ]]; then
      run_cmd "GRUB 設定ファイルにパラメータを追加" bash -c "
        if [[ -f /mnt/etc/default/grub ]]; then
          sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1${extra_options}\"/' /mnt/etc/default/grub
        fi
      "
    fi

    run_cmd "grub.cfg 生成" \
      arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
  fi
}

do_aur_helper() {
  local helper="${CONFIG[aur_helper]}"
  [[ "$helper" == "none" ]] && return

  # 代表ユーザー名を取得（CONFIG[users] の最初のユーザー）
  local first_user
  first_user=$(echo "${CONFIG[users]}" | head -n1 | cut -d'|' -f1)
  if [[ -z "$first_user" ]]; then
    print_warn "一般ユーザーが登録されていないため、AUR ヘルパーのインストールをスキップします。"
    return
  fi

  print_step "AUR ヘルパーインストール: ${helper} (ユーザー: ${first_user})"

  # ドライランのときはスキップ
  if [[ "${CONFIG[dry_run]}" == "yes" ]]; then
    print_warn "ドライランのため AUR ヘルパーのインストールをスキップします"
    return
  fi

  # chroot内ネットワーク接続性の事前確認（git ls-remote を使用）
  local repo_name="$helper"
  [[ "$helper" == "yay" ]] && repo_name="yay-bin"

  echo -ne "  ${CYAN}…${RESET} chroot 内のネットワーク接続を確認中..."
  if ! arch-chroot /mnt git ls-remote "https://aur.archlinux.org/${repo_name}.git" &>/dev/null; then
    echo -e "\r  ${RED}✘${RESET} chroot 内で AUR サーバーに接続できません"
    print_warn "DNS設定（/etc/resolv.conf）の同期不良などの可能性があります。"
    print_warn "AUR ヘルパー (${helper}) のインストールをスキップします。"
    return
  else
    echo -e "\r  ${GREEN}✔${RESET} chroot 内のネットワーク接続OK"
  fi

  run_cmd "AUR リポジトリのクローン (${repo_name})" \
    arch-chroot /mnt bash -c "
      mkdir -p /tmp/aur-build && \
      cd /tmp/aur-build && \
      git clone https://aur.archlinux.org/${repo_name}.git && \
      chown -R ${first_user}: /tmp/aur-build
    "

  # makepkg はユーザー権限で実行
  run_cmd "${helper} ビルド & インストール" \
    arch-chroot /mnt bash -c "
      cd /tmp/aur-build/${repo_name} && \
      sudo -u ${first_user} makepkg -si --noconfirm
    "

  # 後片付け
  run_cmd "ビルドディレクトリの削除" \
    arch-chroot /mnt rm -rf /tmp/aur-build
}

# ============================================
# 実行: デスクトップ環境
# ============================================

do_desktop() {
  [[ "${CONFIG[desktop]}" == "none" ]] && return

  print_step "デスクトップ環境のインストール: ${CONFIG[desktop]}"

  # 音声・Bluetooth・ファイルシステム・マルチメディア・ブラウザなどのデスクトップ共通パッケージ
  local desktop_common_pkgs=(
    pipewire pipewire-pulse wireplumber
    pipewire-alsa pipewire-jack libldac
    bluez bluez-utils
    xdg-user-dirs
    firefox
    ntfs-3g exfatprogs
    gvfs gvfs-mtp
    gst-plugins-good gst-libav
    libdvdcss libdvdread libdvdnav
  )

  case "${CONFIG[desktop]}" in
    kde)
      local pkgs=(sddm-kcm konsole dolphin colord-kde sddm)
      if [[ "${CONFIG[kde_apps]}" == "minimal" ]]; then
        pkgs+=(plasma-desktop)
      elif [[ "${CONFIG[kde_apps]}" == "standard" ]]; then
        pkgs+=(plasma-meta)
      elif [[ "${CONFIG[kde_apps]}" == "full" ]]; then
        pkgs+=(plasma-meta kde-applications)
      else
        pkgs+=(plasma-desktop)
      fi
      run_cmd "KDE Plasma インストール" \
        arch-chroot /mnt pacman -S --noconfirm "${pkgs[@]}" "${desktop_common_pkgs[@]}"
      ;;

    gnome)
      local pkgs=(gnome gnome-tweaks)
      run_cmd "GNOME インストール" \
        arch-chroot /mnt pacman -S --noconfirm "${pkgs[@]}" "${desktop_common_pkgs[@]}"
      
      # gnome-initial-setupをパッケージレベルで削除して初期ウィザードを確実にスキップ
      run_cmd "GNOME 初期セットアップウィザード無効化 (パッケージ削除)" \
        arch-chroot /mnt pacman -Rns --noconfirm gnome-initial-setup 2>/dev/null || true

      # gnome-keyringの有効化（Polkit等と親和性）
      run_cmd "GNOME パッケージインストール (gnome-keyring)" arch-chroot /mnt pacman -S --noconfirm gnome-keyring
      ;;

    xfce)
      local pkgs=(xfce4 xfce4-goodies lightdm lightdm-gtk-greeter)
      run_cmd "Xfce インストール" \
        arch-chroot /mnt pacman -S --noconfirm "${pkgs[@]}" "${desktop_common_pkgs[@]}"
      ;;

    budgie)
      local pkgs=(budgie budgie-control-center lightdm lightdm-gtk-greeter)
      run_cmd "Budgie インストール" \
        arch-chroot /mnt pacman -S --noconfirm "${pkgs[@]}" "${desktop_common_pkgs[@]}"
      print_ok "Budgie 10.10+ (Wayland 対応)"
      print_warn "mutter/gnome-settings-daemon が Budgie の依存関係としてインストールされているか確認してください。"
      ;;

    cosmic)
      # Cosmic desktop (AUR or extra-testing)
      local pkgs=(cosmic)
      run_cmd "COSMIC インストール" \
        arch-chroot /mnt pacman -S --noconfirm "${pkgs[@]}" "${desktop_common_pkgs[@]}"
      ;;

    sway)
      local pkgs=(sway swaybg swayidle swaylock
                  waybar wmenu foot
                  xwayland
                  xdg-desktop-portal-wlr xdg-desktop-portal-gtk
                  pavucontrol polkit-gnome
                  blueman
                  network-manager-applet
                  grim slurp wl-clipboard
                  mako
                  brightnessctl
                  thunar
                  mousepad imv zathura zathura-pdf-mupdf mpv xarchiver
                  ttf-jetbrains-mono-nerd)
      run_cmd "Sway インストール" \
        arch-chroot /mnt pacman -S --noconfirm "${pkgs[@]}" "${desktop_common_pkgs[@]}"
      
      mkdir -p /mnt/etc/skel/.config/sway
      if [ ! -f /mnt/etc/skel/.config/sway/config ]; then
        if ! cp /mnt/usr/share/doc/sway/config /mnt/etc/skel/.config/sway/config 2>/dev/null; then
          cat > /mnt/etc/skel/.config/sway/config << 'EOF'
# Sway 最小フォールバック設定
set $mod Mod4
bindsym $mod+Return exec alacritty
bindsym $mod+Shift+q kill
bindsym $mod+Shift+e exec swaynag -t warning -m 'Exit Sway?' -B 'Yes' 'swaymsg exit'
EOF
        fi
      fi
      
      # 自動起動設定（nm-appletの追加）
      echo 'exec nm-applet --indicator' >> /mnt/etc/skel/.config/sway/config
      if [[ "${CONFIG[jp_ime]:-none}" =~ ^fcitx5 ]]; then
        echo 'exec fcitx5 -d' >> /mnt/etc/skel/.config/sway/config
      fi

      # polkit-gnome 認証エージェントの自動起動設定
      echo 'exec /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1' >> /mnt/etc/skel/.config/sway/config

      # デフォルトの swaybar を無効化（bar { から末尾までを削除）
      sed -i '/^[[:space:]]*bar[[:space:]]*/,$d' /mnt/etc/skel/.config/sway/config

      # Waybar 設定の配置
      mkdir -p /mnt/etc/skel/.config/waybar
      cat > /mnt/etc/skel/.config/waybar/config.jsonc << 'WEOF'
{
    "layer": "top",
    "position": "top",
    "height": 30,
    "spacing": 4,
    "modules-left": [
        "sway/workspaces",
        "sway/mode",
        "sway/scratchpad"
    ],
    "modules-center": [
        "clock"
    ],
    "modules-right": [
        "pulseaudio",
        "battery",
        "tray"
    ],
    "sway/workspaces": {
        "disable-scroll": true,
        "all-outputs": true,
        "format": "{name}"
    },
    "clock": {
        "timezone": "Asia/Tokyo",
        "tooltip-format": "<big>{:%Y %B}</big>\n<tt><small>{calendar}</small></tt>",
        "format": "{:%Y-%m-%d %H:%M:%S}",
        "interval": 1
    },
    "pulseaudio": {
        "format": " {volume}%",
        "format-muted": " Muted",
        "on-click": "pavucontrol"
    },
    "battery": {
        "states": {
            "warning": 30,
            "critical": 15
        },
        "format": "{icon} {capacity}%",
        "format-charging": " {capacity}%",
        "format-plugged": " {capacity}%",
        "format-icons": ["", "", "", "", ""]
    },
    "tray": {
        "spacing": 10
    }
}
WEOF

      cat > /mnt/etc/skel/.config/waybar/style.css << 'WEOF'
#waybar {
    background-color: rgba(26, 27, 38, 0.95);
    border-bottom: 1px solid rgba(255, 255, 255, 0.1);
    color: #c0caf5;
    font-family: "JetBrainsMono Nerd Font", "Noto Sans CJK JP", sans-serif;
    font-size: 13px;
}
#workspaces button {
    padding: 0 5px;
    background-color: transparent;
    color: #c0caf5;
}
#workspaces button.focused {
    background-color: #7aa2f7;
    color: #1a1b26;
    border-radius: 4px;
}
#clock, #pulseaudio, #battery, #tray {
    padding: 0 10px;
    margin: 4px 0;
}
#tray {
    background-color: rgba(255, 255, 255, 0.05);
    border-radius: 4px;
    margin: 4px 10px;
    padding: 0 6px;
}
WEOF

      # Waybar タイムゾーン設定の適用
      sed -i 's|"timezone": "Asia/Tokyo"|"timezone": "'"${CONFIG[timezone]:-Asia/Tokyo}"'"|g' /mnt/etc/skel/.config/waybar/config.jsonc

      # waybar の自動起動設定
      echo 'exec waybar' >> /mnt/etc/skel/.config/sway/config

      # 音量・輝度キーバインドの設定追加
      cat >> /mnt/etc/skel/.config/sway/config << 'EOF'

# 音量・輝度キーのバインド（wpctl / brightnessctl 利用）
bindsym --locked XF86AudioRaiseVolume exec wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+ -l 1.0
bindsym --locked XF86AudioLowerVolume exec wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
bindsym --locked XF86AudioMute exec wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
bindsym --locked XF86AudioMicMute exec wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle
bindsym --locked XF86MonBrightnessUp exec brightnessctl set 10%+
bindsym --locked XF86MonBrightnessDown exec brightnessctl set 10%-

# Waybar の表示トグル（非表示 / 再起動）
bindsym $mod+b exec pkill waybar || waybar
EOF
      ;;

    hyprland)
      local pkgs=(hyprland hyprpaper hyprlock hypridle
                  waybar wofi kitty
                  xwayland
                  xdg-desktop-portal-hyprland xdg-desktop-portal-gtk
                  pavucontrol polkit-gnome
                  blueman
                  network-manager-applet
                  grim slurp wl-clipboard
                  mako
                  brightnessctl
                  thunar
                  mousepad imv zathura zathura-pdf-mupdf mpv xarchiver
                  ttf-jetbrains-mono-nerd)
      run_cmd "Hyprland インストール" \
        arch-chroot /mnt pacman -S --noconfirm "${pkgs[@]}" "${desktop_common_pkgs[@]}"

      # デフォルト設定コピー & コピー失敗時の最小フォールバック
      mkdir -p /mnt/etc/skel/.config/hypr
      local copied=0
      if [ -f /mnt/usr/share/hypr/hyprland.conf ]; then
        cp /mnt/usr/share/hypr/hyprland.conf /mnt/etc/skel/.config/hypr/hyprland.conf && copied=1
      elif [ -f /mnt/etc/xdg/hypr/hyprland.conf ]; then
        cp /mnt/etc/xdg/hypr/hyprland.conf /mnt/etc/skel/.config/hypr/hyprland.conf && copied=1
      fi
      if [ $copied -eq 0 ]; then
        cat > /mnt/etc/skel/.config/hypr/hyprland.conf << 'EOF'
# Hyprland 最小フォールバック設定
monitor=,preferred,auto,auto
$mainMod = SUPER
bind = $mainMod, Q, exec, kitty
bind = $mainMod, C, killactive,
bind = $mainMod, M, exit,
EOF
      fi

      # 自動起動設定（nm-applet of 接続）
      echo 'exec-once = nm-applet --indicator' >> /mnt/etc/skel/.config/hypr/hyprland.conf
      if [[ "${CONFIG[jp_ime]:-none}" =~ ^fcitx5 ]]; then
        echo 'exec-once = fcitx5 -d' >> /mnt/etc/skel/.config/hypr/hyprland.conf
      fi

      # polkit-gnome 認証エージェントの自動起動設定
      echo 'exec-once = /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1' >> /mnt/etc/skel/.config/hypr/hyprland.conf

      # Waybar 設定の配置
      mkdir -p /mnt/etc/skel/.config/waybar
      cat > /mnt/etc/skel/.config/waybar/config.jsonc << 'WEOF'
{
    "layer": "top",
    "position": "top",
    "height": 30,
    "spacing": 4,
    "modules-left": [
        "hyprland/workspaces",
        "hyprland/submap"
    ],
    "modules-center": [
        "clock"
    ],
    "modules-right": [
        "pulseaudio",
        "battery",
        "tray"
    ],
    "hyprland/workspaces": {
        "disable-scroll": true,
        "all-outputs": true,
        "format": "{name}"
    },
    "clock": {
        "timezone": "Asia/Tokyo",
        "tooltip-format": "<big>{:%Y %B}</big>\n<tt><small>{calendar}</small></tt>",
        "format": "{:%Y-%m-%d %H:%M:%S}",
        "interval": 1
    },
    "pulseaudio": {
        "format": " {volume}%",
        "format-muted": " Muted",
        "on-click": "pavucontrol"
    },
    "battery": {
        "states": {
            "warning": 30,
            "critical": 15
        },
        "format": "{icon} {capacity}%",
        "format-charging": " {capacity}%",
        "format-plugged": " {capacity}%",
        "format-icons": ["", "", "", "", ""]
    },
    "tray": {
        "spacing": 10
    }
}
WEOF

      cat > /mnt/etc/skel/.config/waybar/style.css << 'WEOF'
#waybar {
    background-color: rgba(26, 27, 38, 0.95);
    border-bottom: 1px solid rgba(255, 255, 255, 0.1);
    color: #c0caf5;
    font-family: "JetBrainsMono Nerd Font", "Noto Sans CJK JP", sans-serif;
    font-size: 13px;
}
#workspaces button {
    padding: 0 5px;
    background-color: transparent;
    color: #c0caf5;
}
#workspaces button.active {
    background-color: #7aa2f7;
    color: #1a1b26;
    border-radius: 4px;
}
#clock, #pulseaudio, #battery, #tray {
    padding: 0 10px;
    margin: 4px 0;
}
#tray {
    background-color: rgba(255, 255, 255, 0.05);
    border-radius: 4px;
    margin: 4px 10px;
    padding: 0 6px;
}
WEOF

      # Waybar タイムゾーン設定 of 適用
      sed -i 's|"timezone": "Asia/Tokyo"|"timezone": "'"${CONFIG[timezone]:-Asia/Tokyo}"'"|g' /mnt/etc/skel/.config/waybar/config.jsonc

      # waybar の自動起動設定
      echo 'exec-once = waybar' >> /mnt/etc/skel/.config/hypr/hyprland.conf

      # 音量・輝度キーバインドの設定追加
      cat >> /mnt/etc/skel/.config/hypr/hyprland.conf << 'EOF'

# 音量・輝度キーのバインド（wpctl / brightnessctl 利用）
bindel = , XF86AudioRaiseVolume, exec, wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+
bindel = , XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
bindl = , XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
bindl = , XF86AudioMicMute, exec, wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle
bindel = , XF86MonBrightnessUp, exec, brightnessctl set 10%+
bindel = , XF86MonBrightnessDown, exec, brightnessctl set 10%-

# Waybar の表示トグル（非表示 / 再起動）
bind = SUPER, B, exec, pkill waybar || waybar
EOF
      ;;

    niri)
      local pkgs=(niri xwayland-satellite
                  waybar swaybg swaylock mako
                  alacritty fuzzel
                  xdg-desktop-portal-gnome xdg-desktop-portal-gtk
                  pavucontrol polkit-gnome
                  blueman
                  network-manager-applet
                  grim slurp wl-clipboard
                  brightnessctl
                  thunar
                  mousepad imv zathura zathura-pdf-mupdf mpv xarchiver
                  ttf-jetbrains-mono-nerd)
      run_cmd "Niri インストール" \
        arch-chroot /mnt pacman -S --noconfirm "${pkgs[@]}" "${desktop_common_pkgs[@]}"

      # デフォルト設定ファイルのコピー
      mkdir -p /mnt/etc/skel/.config/niri
      if [ -f /mnt/usr/share/doc/niri/default-config.kdl ]; then
        cp /mnt/usr/share/doc/niri/default-config.kdl /mnt/etc/skel/.config/niri/config.kdl
      elif [ -f /mnt/usr/share/doc/niri/config.kdl ]; then
        cp /mnt/usr/share/doc/niri/config.kdl /mnt/etc/skel/.config/niri/config.kdl
      fi

      # Waybar 設定の配置
      mkdir -p /mnt/etc/skel/.config/waybar
      cat > /mnt/etc/skel/.config/waybar/config.jsonc << 'WEOF'
{
    "layer": "top",
    "position": "top",
    "height": 30,
    "spacing": 4,
    "modules-left": [
        "niri/workspaces"
    ],
    "modules-center": [
        "clock"
    ],
    "modules-right": [
        "pulseaudio",
        "battery",
        "tray"
    ],
    "niri/workspaces": {
        "format": "{name}"
    },
    "clock": {
        "timezone": "Asia/Tokyo",
        "tooltip-format": "<big>{:%Y %B}</big>\n<tt><small>{calendar}</small></tt>",
        "format": "{:%Y-%m-%d %H:%M:%S}",
        "interval": 1
    },
    "pulseaudio": {
        "format": " {volume}%",
        "format-muted": " Muted",
        "on-click": "pavucontrol"
    },
    "battery": {
        "states": {
            "warning": 30,
            "critical": 15
        },
        "format": "{icon} {capacity}%",
        "format-charging": " {capacity}%",
        "format-plugged": " {capacity}%",
        "format-icons": ["", "", "", "", ""]
    },
    "tray": {
        "spacing": 10
    }
}
WEOF

      cat > /mnt/etc/skel/.config/waybar/style.css << 'WEOF'
#waybar {
    background-color: rgba(26, 27, 38, 0.95);
    border-bottom: 1px solid rgba(255, 255, 255, 0.1);
    color: #c0caf5;
    font-family: "JetBrainsMono Nerd Font", "Noto Sans CJK JP", sans-serif;
    font-size: 13px;
}
#workspaces button {
    padding: 0 5px;
    background-color: transparent;
    color: #c0caf5;
}
#workspaces button.active {
    background-color: #7aa2f7;
    color: #1a1b26;
    border-radius: 4px;
}
#clock, #pulseaudio, #battery, #tray {
    padding: 0 10px;
    margin: 4px 0;
}
#tray {
    background-color: rgba(255, 255, 255, 0.05);
    border-radius: 4px;
    margin: 4px 10px;
    padding: 0 6px;
}
WEOF

      # Waybar タイムゾーン設定 of 適用
      sed -i 's|"timezone": "Asia/Tokyo"|"timezone": "'"${CONFIG[timezone]:-Asia/Tokyo}"'"|g' /mnt/etc/skel/.config/waybar/config.jsonc

      # 自動起動設定（nm-appletの追加）
      echo 'spawn-at-startup "nm-applet" "--indicator"' >> /mnt/etc/skel/.config/niri/config.kdl
      if [[ "${CONFIG[jp_ime]:-none}" =~ ^fcitx5 ]]; then
        echo 'spawn-at-startup "fcitx5" "-d"' >> /mnt/etc/skel/.config/niri/config.kdl
      fi

      # Waybar の表示トグル設定追加
      echo 'binds { Mod+B { spawn "sh" "-c" "pkill waybar || waybar"; } }' >> /mnt/etc/skel/.config/niri/config.kdl

      # polkit-gnome 認証エージェントの自動起動設定
      echo 'spawn-at-startup "/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1"' >> /mnt/etc/skel/.config/niri/config.kdl
      print_ok "スクロール型タイリング: 横スクロールで無限ワークスペース"
      ;;
  esac
}
do_display_manager() {
  local dm="${CONFIG[dm]}"
  [[ "$dm" == "none" ]] && { print_ok "DM なし: TTY から手動起動"; return; }

  print_step "ディスプレイマネージャーのセットアップ: ${dm}"

  case "$dm" in
    sddm)
      run_cmd "SDDM インストール" \
        arch-chroot /mnt pacman -S --noconfirm sddm
      run_cmd "SDDM 有効化" arch-chroot /mnt systemctl enable sddm
      ;;

    gdm)
      run_cmd "GDM インストール" \
        arch-chroot /mnt pacman -S --noconfirm gdm
      run_cmd "GDM 有効化" arch-chroot /mnt systemctl enable gdm
      ;;

    lightdm)
      run_cmd "LightDM インストール" \
        arch-chroot /mnt pacman -S --noconfirm \
          lightdm lightdm-gtk-greeter
      run_cmd "LightDM 有効化" arch-chroot /mnt systemctl enable lightdm
      ;;

    cosmic-greeter)
      run_cmd "cosmic-greeter インストール" \
        arch-chroot /mnt pacman -S --noconfirm cosmic-greeter
      run_cmd "cosmic-greeter 有効化" \
        arch-chroot /mnt systemctl enable cosmic-greeter
      ;;

    greetd)
      run_cmd "greetd インストール" \
        arch-chroot /mnt pacman -S --noconfirm greetd tuigreet

      # セッションコマンドを DE に応じて決める
      local session_cmd
      case "${CONFIG[desktop]}" in
        sway)     session_cmd="sway" ;;
        hyprland) session_cmd="Hyprland" ;;
        niri)     session_cmd="niri-session" ;;
        kde)      session_cmd="startplasma-wayland" ;;
        gnome)    session_cmd="gnome-shell --wayland" ;;
        *)        session_cmd="bash" ;;
      esac

      # greetd 設定
      mkdir -p /mnt/etc/greetd
      cat > /mnt/etc/greetd/config.toml << EOF
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --remember --cmd ${session_cmd}"
user = "greeter"
EOF
      run_cmd "greetd 有効化" arch-chroot /mnt systemctl enable greetd
      print_ok "greetd: セッションコマンド = ${session_cmd}"
      ;;
  esac
}
do_cleanup() {
  print_step "後処理"
  # swapoff は swap がない場合でも失敗しないよう直接実行
  echo -ne "  ${CYAN}…${RESET} swap 無効化..."
  swapoff -a 2>/dev/null && echo -e "\r  ${GREEN}✔${RESET} swap 無効化   " || \
    echo -e "\r  ${GREEN}✔${RESET} swap なし（スキップ）"
  run_cmd "アンマウント" umount -R /mnt
}

# ============================================
# インストール実行
# ============================================

run_install() {
  if [[ "${CONFIG[dry_run]}" != "yes" ]]; then
    echo "" > "${CONFIG[log_file]}"
    print_ok "ログファイル: ${CONFIG[log_file]}"
  else
    print_warn "ドライランモードで動作中（変更は適用されません）"
  fi

  do_partition
  do_format_and_mount
  do_mirrorlist
  do_pacstrap
  do_fstab
  do_chroot_config
  do_users
  do_aur_helper
  do_bootloader
  do_desktop
  do_display_manager
  do_cleanup

  echo ""
  echo -e "${GREEN}${BOLD}"
  echo "╔══════════════════════════════════════════╗"
  echo "║   インストール完了！再起動してください   ║"
  echo "╚══════════════════════════════════════════╝"
  echo -e "${RESET}"
  echo -e "  再起動コマンド: ${BOLD}reboot${RESET}"

  # 外付けディスクへのインストール時は起動方法を案内
  if [[ "${CONFIG[disk_is_external]:-no}" == "yes" ]]; then
    echo ""
    echo -e "${YELLOW}${BOLD}  ── 外付けディスクからの起動について ──${RESET}"
    echo -e "  外付け SSD/HDD からブートするには、UEFI/BIOS で"
    echo -e "  起動順序（Boot Order）を変更する必要があります。\n"
    echo -e "  ${BOLD}一般的な手順:${RESET}"
    echo -e "    1. 再起動時に ${BOLD}F2 / F12 / Del / Esc${RESET} を連打"
    echo -e "       （メーカーにより異なります）"
    echo -e "    2. UEFI/BIOS メニューで ${BOLD}Boot${RESET} タブを開く"
    echo -e "    3. 外付けデバイス（USB や External NVMe）を最上位に移動"
    echo -e "    4. 設定を保存して再起動\n"
    echo -e "  ${BOLD}UEFI から一時的に起動デバイスを選ぶ場合:${RESET}"
    echo -e "    再起動時に ${BOLD}F12${RESET}（または F8/F10）を押して"
    echo -e "    Boot Menu を開き、外付けデバイスを選択してください。\n"
    echo -e "  ${BOLD}インストール済み Arch の UEFI エントリを確認:${RESET}"
    echo -e "    ${BOLD}efibootmgr -v${RESET}"
  fi
}

# ============================================
# メイン
# ============================================

main() {
  # root チェック
  if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}エラー: このスクリプトは root で実行してください。${RESET}"
    echo "  例: sudo bash install.sh"
    exit 1
  fi

  # 仮想環境検出
  local virt=""
  if command -v systemd-detect-virt &>/dev/null; then
    virt=$(systemd-detect-virt 2>/dev/null || echo "none")
  else
    virt="none"
  fi
  CONFIG[virt_env]="$virt"
  if [[ "$virt" != "none" ]]; then
    print_ok "仮想環境を検出しました: $virt"
  fi

  # Live環境の pacman.conf チューニング
  if [[ -f /etc/pacman.conf ]] && [[ "${CONFIG[dry_run]}" != "yes" ]]; then
    sed -i 's/^#Color$/Color/' /etc/pacman.conf
    sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
    sed -i '/^#\[multilib\]/,/^#Include = \/etc\/pacman.d\/mirrorlist/s/^#//' /etc/pacman.conf
  fi

  print_header
  echo -e "  Arch Linux の自動インストールを開始します。"
  echo -e "  各ステップで設定を入力してください。\n"

  if ! confirm "開始しますか？"; then
    echo "中断しました。"
    exit 0
  fi

  check_network

  step_disk
  step_partition_scheme
  step_system
  step_users
  step_bootloader
  step_desktop
  step_network
  step_mirror
  step_fonts
  step_extra_packages

  show_summary

  if confirm "インストールを実行しますか？"; then
    run_install
  else
    echo -e "\n  インストールを中断しました。"
    exit 0
  fi
}

main "$@"
