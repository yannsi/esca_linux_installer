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
DIM='\033[2m'
GRAY='\033[0;90m'
MAGENTA='\033[0;35m'
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
  [timezone]="Asia/Tokyo"
  [locale]="ja_JP.UTF-8"
  [keymap]="jp106"
  [bootloader]="systemd-boot"
  [boot_mode]=""
  [partition_scheme]=""
  [fs_type]="ext4"
  [desktop]="none"
  [kde_apps]="none"
  [dm]="none"
  [root_password]=""
  [users]=""
  [users_count]="0"
  [japanese_env]="yes"
  [jp_ime]="fcitx5-mozc"
  [wifi_backend]="none"
  [use_resolved]="no"
  [mirror_mode]="keep"
  [mirror_host]=""
  [dualboot_windows]="no"
  [extra_base_devel]="yes"
  [extra_zram]="yes"
  [extra_pkgs]=""
  [font_pkgs]="noto-fonts noto-fonts-cjk noto-fonts-emoji"
  [font_setup_fontconfig]="yes"
  [dry_run]="$DRY_RUN"
  [log_file]="$LOG_FILE"
  [gpu_driver]="none"
  [aur_helper]="yay"
  [extra_ssh]="yes"
  [extra_ufw]="no"
  [extra_fstrim]="yes"
  [install_chrome]="yes"
  [install_ytfzf]="yes"
  [virt_env]="none"
  [cpu_vendor]=""
  [mirror_country]="Japan"
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

# インストーラを実行しているユーザーのホームディレクトリを推定する。
# sudo 実行時は SUDO_USER、それ以外は /home 直下の実ユーザーを探す。
# 見つからなければ空文字を返す（＝ホスト設定コピー機能は自動でスキップ）。
_host_home() {
  if [[ -n "${SUDO_USER:-}" && -d "/home/${SUDO_USER}" ]]; then
    echo "/home/${SUDO_USER}"
    return
  fi
  local d
  for d in /home/*; do
    [[ -d "$d" ]] || continue
    echo "$d"
    return
  done
  echo ""
}

# ============================================
# ユーティリティ関数
# ============================================

print_header() {
  clear
  echo ""
  echo -e "  ${CYAN}${BOLD}myarchinstall${RESET}  ${GRAY}│${RESET}  ${DIM}日本語環境セットアップ for Arch Linux${RESET}"
  echo -e "  ${CYAN}$(printf '━%.0s' {1..48})${RESET}"
  echo ""
}

print_step() {
  print_header
  if [[ "${STEP_TOTAL:-0}" -gt 0 ]]; then
    STEP_NUM=$(( ${STEP_NUM:-0} + 1 ))
    echo -e "  ${MAGENTA}${BOLD}[${STEP_NUM}/${STEP_TOTAL}]${RESET} ${BLUE}${BOLD}▶ $1${RESET}"
  else
    echo -e "  ${BLUE}${BOLD}▶ $1${RESET}"
  fi
  echo -e "  ${BLUE}${DIM}$(printf '─%.0s' {1..48})${RESET}"
  echo ""
}

print_ok()   { echo -e "  ${GREEN}✔${RESET} $1"; }
print_warn() { echo -e "  ${YELLOW}⚠${RESET} $1"; }
print_err()  { echo -e "  ${RED}✘${RESET} $1"; }

# 出力/入力に使う tty を解決する（/dev/tty が使えなければ stderr/stdin へフォールバック）。
# 使い方: local tty_out tty_in; _resolve_tty tty_out tty_in
_resolve_tty() {
  local -n _out_ref="$1" _in_ref="$2"
  _out_ref="/dev/tty"; [[ -w /dev/tty ]] || _out_ref="/dev/stderr"
  _in_ref="/dev/tty";  [[ -r /dev/tty ]] || _in_ref="/dev/stdin"
}

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
    # カーネルの直近エラーもログに追記
    echo "--- dmesg (直近10行) ---" >> "${CONFIG[log_file]}"
    dmesg 2>/dev/null | tail -10 >> "${CONFIG[log_file]}" || true
    exit 1
  fi
}

run_cmd_retry() {
  # ネットワーク系コマンド用: 失敗時に最大3回リトライする
  local desc="$1"; shift
  local max_attempts=3
  local attempt=1
  while [[ "$attempt" -le "$max_attempts" ]]; do
    if [[ "$attempt" -gt 1 ]]; then
      echo -ne "  ${CYAN}…${RESET} ${desc}（リトライ ${attempt}/${max_attempts}）..."
    else
      echo -ne "  ${CYAN}…${RESET} ${desc}..."
    fi
    if [[ "${CONFIG[dry_run]}" == "yes" ]]; then
      echo -e "\r  ${YELLOW}⚠${RESET} ${desc} (ドライラン - スキップ)"
      return 0
    fi
    if "$@" >> "${CONFIG[log_file]}" 2>&1; then
      echo -e "\r  ${GREEN}✔${RESET} ${desc}   "
      return 0
    fi
    echo -e "\r  ${YELLOW}⚠${RESET} ${desc} — 失敗 (試行 ${attempt}/${max_attempts})"
    attempt=$(( attempt + 1 ))
    if [[ "$attempt" -le "$max_attempts" ]]; then
      echo -e "  ${YELLOW}…${RESET} 10秒後にリトライします..."
      sleep 10
    fi
  done
  echo -e "  ${RED}✘${RESET} ${desc} — ${max_attempts}回試行しましたが失敗しました"
  print_err "ログ: ${CONFIG[log_file]}"
  exit 1
}

run_cmd_soft() {
  # 失敗してもインストールを継続する（Google Chrome 等の任意処理用）。
  local desc="$1"; shift
  echo -ne "  ${CYAN}…${RESET} ${desc}..."
  if [[ "${CONFIG[dry_run]}" == "yes" ]]; then
    echo -e "\r  ${YELLOW}⚠${RESET} ${desc} (ドライラン - スキップ)"
    return 0
  fi
  if "$@" >> "${CONFIG[log_file]}" 2>&1; then
    echo -e "\r  ${GREEN}✔${RESET} ${desc}   "
    return 0
  fi
  echo -e "\r  ${YELLOW}⚠${RESET} ${desc} — 失敗（スキップして継続）"
  print_warn "このパッケージは後から手動で導入できます。ログ: ${CONFIG[log_file]}"
  return 1
}

ask() {
  local prompt="$1"
  local default="${2:-}"
  local answer
  local tty_out tty_in; _resolve_tty tty_out tty_in
  if [[ -n "$default" ]]; then
    echo -ne "  ${BOLD}${prompt}${RESET} [${default}]: " > "$tty_out"
  else
    echo -ne "  ${BOLD}${prompt}${RESET}: " > "$tty_out"
  fi
  read -r answer < "$tty_in"
  echo "${answer:-$default}"
}

ask_password() {
  local prompt="$1"
  local pw1 pw2
  local tty_out tty_in; _resolve_tty tty_out tty_in
  while true; do
    echo -ne "  ${BOLD}${prompt}${RESET}: " > "$tty_out"
    read -rs pw1 < "$tty_in"; echo > "$tty_out"
    if [[ "$pw1" == *"|"* ]]; then
      echo -e "  ${RED}✘${RESET} パスワードに '|' は使用できません。" > "$tty_out"
      continue
    fi
    echo -ne "  ${BOLD}（確認）${prompt}${RESET}: " > "$tty_out"
    read -rs pw2 < "$tty_in"; echo > "$tty_out"
    if [[ "$pw1" == "$pw2" ]]; then
      echo "$pw1"
      return
    fi
    echo -e "  ${RED}✘${RESET} パスワードが一致しません。もう一度入力してください。" > "$tty_out"
  done
}

confirm() {
  local prompt="${1:-続けますか？}"
  local answer
  local tty_out tty_in; _resolve_tty tty_out tty_in
  while true; do
    echo -ne "  ${BOLD}${prompt}${RESET} [y/N]: " > "$tty_out"
    read -r answer < "$tty_in"
    case "$answer" in
      [yY]) return 0 ;;
      [nN]|"") return 1 ;;
      *) echo -e "  ${RED}✘${RESET} y または n を入力してください。" > "$tty_out" ;;
    esac
  done
}

# confirm の既定 Yes 版（Enter で承認）。日本語環境の推奨項目に使う。
confirm_yes() {
  local prompt="${1:-続けますか？}"
  local answer
  local tty_out tty_in; _resolve_tty tty_out tty_in
  while true; do
    echo -ne "  ${BOLD}${prompt}${RESET} ${GREEN}[Y/n]${RESET}: " > "$tty_out"
    read -r answer < "$tty_in"
    case "$answer" in
      [yY]|"") return 0 ;;
      [nN]) return 1 ;;
      *) echo -e "  ${RED}✘${RESET} y または n を入力してください。" > "$tty_out" ;;
    esac
  done
}

select_from_list() {
  # $() サブシェルで呼ばれても表示されるよう /dev/tty に直接出力する
  local prompt="$1"
  shift
  local options=("$@")
  local tty_out tty_in; _resolve_tty tty_out tty_in

  echo -e "  ${BOLD}${prompt}${RESET}" > "$tty_out"
  for i in "${!options[@]}"; do
    printf "    ${CYAN}%2d)${RESET} %s\n" "$((i+1))" "${options[$i]}" > "$tty_out"
  done
  local choice max
  max="${#options[@]}"
  while true; do
    echo -ne "  番号を入力: " > "$tty_out"
    read -r choice < "$tty_in"
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$max" ]]; then
      echo "${options[$((choice-1))]}"
      return
    fi
    echo -e "  ${RED}✘${RESET} 1〜${max} の番号を入力してください。" > "$tty_out"
  done
}

# CONFIG[users] を行ごとにパースして変数に展開するヘルパー
# 使い方: parse_users_line "$entry"  → uname/upw/usudo/ushell/ugroups をセット
# chroot 内のユーザーにパスワードを設定する（特殊文字対応・tmpfile 経由）
_set_password() {
  local user="$1"
  local pw="$2"
  if [[ "${CONFIG[dry_run]}" == "yes" ]]; then
    print_warn "_set_password: ${user} (ドライラン - スキップ)"
    return 0
  fi
  local tmpfile
  tmpfile=$(mktemp)
  printf "%s:%s" "$user" "$pw" > "$tmpfile"
  arch-chroot /mnt chpasswd < "$tmpfile"
  rm -f "$tmpfile"
}

parse_users_line() {
  local entry="$1"
  uname=$(cut -d'|' -f1  <<< "$entry")
  upw=$(cut -d'|' -f2    <<< "$entry")
  usudo=$(cut -d'|' -f3  <<< "$entry")
  ushell=$(cut -d'|' -f4 <<< "$entry")
  ugroups=$(cut -d'|' -f5 <<< "$entry")
}

# pacman.conf を最適化する（Color有効化・並列DL・multilib有効化）
# 引数: 対象ファイルのパス（例: /etc/pacman.conf または /mnt/etc/pacman.conf）
tune_pacman_conf() {
  local conf="$1"
  [[ -f "$conf" ]] || return 0
  sed -i 's/^#Color$/Color/'                                                        "$conf"
  sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/'                           "$conf"
  sed -i '/^#\[multilib\]/,/^#Include = \/etc\/pacman.d\/mirrorlist/s/^#//'        "$conf"
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
  local iso_dev=""
  iso_dev=$(findmnt -n -o SOURCE /run/archiso/bootmnt 2>/dev/null || \
            findmnt -n -o SOURCE /run/miso 2>/dev/null || true)
  # パーティション番号を除いてデバイス名だけ取り出す（例: /dev/sda1 → sda）
  if [[ -n "$iso_dev" ]]; then
    local iso_dev_name="${iso_dev#/dev/}"
    if [[ -d "/sys/class/block/${iso_dev_name}" ]]; then
      # sysfs から親デバイス名（PKNAME 相当）を取得
      if [[ -f "/sys/class/block/${iso_dev_name}/partition" ]]; then
        iso_dev=$(basename "$(readlink -f "/sys/class/block/${iso_dev_name}/..")" 2>/dev/null || echo "$iso_dev_name")
      else
        iso_dev="$iso_dev_name"
      fi
    else
      iso_dev=$(echo "$iso_dev" | sed 's|/dev/||; s|[0-9]*$||; s|p[0-9]*$||')
    fi
  fi

  # ディスク一覧を構築（sysfs から直接読み取り、loop・光学・ISO デバイスを除外）
  local disks=()
  for devpath in /sys/block/*; do
    [[ -e "$devpath" ]] || continue
    local devname
    devname=$(basename "$devpath")

    # loop, ram, sr, zram デバイスを除外
    [[ "$devname" =~ ^(loop|ram|sr|zram) ]] && continue

    # サイズが 0（または読み取れない）デバイスを除外
    local sectors
    sectors=$(cat "$devpath/size" 2>/dev/null || echo 0)
    # (( sectors == 0 )) は set -e で終了するため [[ ]] で比較
    [[ "$sectors" -eq 0 ]] && continue

    # ISO デバイスをスキップ
    [[ -n "$iso_dev" && "$devname" == "$iso_dev" ]] && continue

    # サイズを人間が読みやすい形式に変換
    local bytes
    bytes=$(( sectors * 512 ))
    local size_str
    # (( bytes >= N )) は false のとき終了コード1 → set -e で終了するため if で保護
    if [[ "$bytes" -ge 1099511627776 ]]; then
      size_str="$(( bytes / 1099511627776 ))T"
    elif [[ "$bytes" -ge 1073741824 ]]; then
      size_str="$(( bytes / 1073741824 ))G"
    elif [[ "$bytes" -ge 1048576 ]]; then
      size_str="$(( bytes / 1048576 ))M"
    else
      size_str="${bytes}B"
    fi

    # モデル名を取得
    local model=""
    if [[ -f "$devpath/device/model" ]]; then
      model=$(tr -d '\r\n' < "$devpath/device/model" | xargs)
    elif [[ -f "$devpath/device/name" ]]; then
      model=$(tr -d '\r\n' < "$devpath/device/name" | xargs)
    fi

    # 接続タイプを sysfs パスから判定
    local sys_link
    sys_link=$(readlink -f "$devpath" 2>/dev/null || echo "")
    local label=""
    if [[ "$sys_link" == *"/usb"* ]]; then
      label=" [外付け USB]"
    elif [[ "$sys_link" == *"/nvme"* ]]; then
      label=" [NVMe]"
    elif [[ "$sys_link" == *"/ata"* ]]; then
      label=" [SATA]"
    fi

    disks+=("/dev/${devname} (${size_str}) ${model}${label}")
  done

  if [[ ${#disks[@]} -eq 0 ]]; then
    print_err "インストール先ディスクが見つかりません。"
    echo -e "\n${YELLOW}─── デバッグ・診断情報 ───${RESET}"
    echo "除外対象 (iso_dev)  : ${iso_dev:-なし}"
    echo "利用可能な /sys/block デバイス一覧:"
    ls /sys/block || true
    echo -e "─────────────────────────\n"
    exit 1
  fi

  # ISO デバイスを除外した旨を表示
  if [[ -n "$iso_dev" ]]; then
    print_ok "Arch ISO デバイス (/dev/${iso_dev}) を候補から除外しました"
  fi

  echo ""
  # ディスク一覧を直接表示して番号選択（配列要素にスペースが含まれるため select_from_list は使わない）
  echo -e "  ${BOLD}インストール先ディスクを選択してください:${RESET}"
  for i in "${!disks[@]}"; do
    printf "    ${CYAN}%2d)${RESET} %s\n" "$((i+1))" "${disks[$i]}"
  done
  local choice max
  max="${#disks[@]}"
  while true; do
    echo -ne "  番号を入力: "
    read -r choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$max" ]]; then
      break
    fi
    print_err "1〜${max} の番号を入力してください。"
  done
  local selected="${disks[$((choice-1))]}"
  CONFIG[disk]=$(echo "$selected" | awk '{print $1}')

  # 外付けディスクかどうかを記録（完了メッセージで案内するため）
  local disk_name="${CONFIG[disk]#/dev/}"
  local disk_sys_link
  disk_sys_link=$(readlink -f "/sys/block/${disk_name}" 2>/dev/null || echo "")
  if [[ "$disk_sys_link" == *"/usb"* ]]; then
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

  # BIOS 環境でも本スクリプトは GPT を使用する（GRUB は BIOS+GPT に対応）
  if [[ "${CONFIG[boot_mode]}" == "bios" ]]; then
    print_warn "BIOS 環境では GPT + BIOS Boot パーティション(1MB) を使用します。"
    print_warn "MBR/DOS 形式を希望する場合は「手動（fdisk）」を選択してください。"
    echo ""
  fi

  local scheme
  scheme=$(select_from_list "パーティション構成を選択:" \
    "自動（推奨） - EFI 512M + / のみ（swap なし・zram 推奨）" \
    "自動 - EFI 512M + swap 4G + /（ハイバネート使用時）" \
    "手動（fdisk を起動）")

  case "$scheme" in
    "自動（推奨） - EFI 512M + / のみ（swap なし・zram 推奨）") CONFIG[partition_scheme]="auto_noswap" ;;
    "自動 - EFI 512M + swap 4G + /（ハイバネート使用時）")       CONFIG[partition_scheme]="auto_swap" ;;
    "手動（fdisk を起動）")                                        CONFIG[partition_scheme]="manual" ;;
  esac
  print_ok "パーティション構成: ${CONFIG[partition_scheme]}"

  # ファイルシステム選択（手動時はユーザーが自分でフォーマットするため省略）
  if [[ "${CONFIG[partition_scheme]}" != "manual" ]]; then
    echo ""
    echo -e "  ${YELLOW}ヒント: よく分からない場合は ext4（推奨）を選んでください。${RESET}"
    local fs
    fs=$(select_from_list "ルートパーティションのファイルシステムを選択:" \
      "ext4   - 安定・実績豊富・推奨（初心者向け）" \
      "btrfs  - スナップショット対応・モダン（中〜上級者向け）" \
      "xfs    - 大容量・高性能（サーバー・上級者向け）")
    case "$fs" in
      "ext4   - 安定・実績豊富・推奨（初心者向け）") CONFIG[fs_type]="ext4" ;;
      "btrfs  - スナップショット対応・モダン（中〜上級者向け）") CONFIG[fs_type]="btrfs" ;;
      "xfs    - 大容量・高性能（サーバー・上級者向け）")         CONFIG[fs_type]="xfs" ;;
    esac
    print_ok "ファイルシステム: ${CONFIG[fs_type]}"
  fi
}

# ============================================
# ステップ 3: システム設定
# ============================================

step_system() {
  print_step "システム設定"

  # --- 日本語環境専用: ロケール・タイムゾーンは固定 ---
  CONFIG[locale]="ja_JP.UTF-8"
  CONFIG[timezone]="Asia/Tokyo"
  CONFIG[japanese_env]="yes"
  print_ok "ロケール    : ja_JP.UTF-8（日本語環境専用）"
  print_ok "タイムゾーン: Asia/Tokyo"

  # --- キーボード配列だけハードウェアに合わせて選択 ---
  echo ""
  local kb
  kb=$(select_from_list "キーボード配列を選択:" \
    "日本語 JIS (jp106) - 一般的な日本語キーボード（推奨）" \
    "US 配列 (us)       - 英字配列（HHKB/US キーボード等）")
  case "$kb" in
    "日本語 JIS"*) CONFIG[keymap]="jp106" ;;
    "US 配列"*)    CONFIG[keymap]="us" ;;
  esac
  print_ok "キーマップ  : ${CONFIG[keymap]}"

  # --- 日本語入力 (IME): 既定でインストール ---
  echo ""
  echo -e "  ${CYAN}${BOLD}── 日本語入力 (IME) ──${RESET}"
  CONFIG[jp_ime]="fcitx5-mozc"
  if confirm_yes "日本語入力 fcitx5 + Mozc をインストールしますか？（推奨）"; then
    CONFIG[jp_ime]="fcitx5-mozc"
    print_ok "IME: fcitx5-mozc"
  else
    local ime
    ime=$(select_from_list "別の IME を選択:" \
      "fcitx5 + anthy" \
      "ibus + mozc" \
      "IME を入れない")
    case "$ime" in
      "fcitx5 + anthy") CONFIG[jp_ime]="fcitx5-anthy" ;;
      "ibus + mozc")    CONFIG[jp_ime]="ibus-mozc" ;;
      *)                CONFIG[jp_ime]="none" ;;
    esac
    print_ok "IME: ${CONFIG[jp_ime]}"
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

  # GPU を自動検出して推奨を提示
  local detected_gpu=""
  local recommended=""
  if lspci 2>/dev/null | grep -qi "NVIDIA"; then
    detected_gpu="NVIDIA"
    recommended="nvidia"
  elif lspci 2>/dev/null | grep -qi "AMD\|ATI\|Radeon"; then
    detected_gpu="AMD"
    recommended="amdgpu"
  elif lspci 2>/dev/null | grep -qi "Intel.*Graphics\|Intel.*VGA"; then
    detected_gpu="Intel"
    recommended="intel"
  elif systemd-detect-virt 2>/dev/null | grep -qiE "oracle|kvm|vmware|qemu"; then
    detected_gpu="仮想環境"
    recommended="virtual"
  fi

  if [[ -n "$detected_gpu" ]]; then
    print_ok "検出された GPU: ${detected_gpu}"
    echo -e "  ${CYAN}→ 推奨: 上記に合わせたドライバーを自動選択できます${RESET}"
    echo ""
    if confirm "検出された GPU（${detected_gpu}）の推奨ドライバーを自動選択しますか？"; then
      CONFIG[gpu_driver]="$recommended"
      print_ok "GPU ドライバー: ${CONFIG[gpu_driver]}（自動選択）"
      return
    fi
  else
    print_warn "GPU を自動検出できませんでした。手動で選択してください。"
    echo ""
  fi

  # 手動選択（自動検出できなかった場合、またはユーザーが手動選択を希望した場合）
  echo -e "  ${YELLOW}ヒント: 自分の PC の GPU メーカーが分からない場合は${RESET}"
  echo -e "  ${YELLOW}「インストールしない」を選ぶと基本的な画面表示は動作します。${RESET}"
  echo ""

  local gpu
  gpu=$(select_from_list "GPU ドライバーを選択してください:" \
    "NVIDIA    - NVIDIA 製 GPU（GeForce など）※ゲーミング PC に多い" \
    "NVIDIA    - NVIDIA 製 GPU（オープンソース版 Nouveau）" \
    "AMD       - AMD 製 GPU（Radeon など）" \
    "Intel     - Intel 内蔵グラフィックス（CPU 内蔵グラフィック）" \
    "仮想環境  - VirtualBox・VMware 上で動かしている場合" \
    "インストールしない - よく分からない場合・後で手動設定")

  case "$gpu" in
    "NVIDIA    - NVIDIA 製 GPU（GeForce など）※ゲーミング PC に多い") CONFIG[gpu_driver]="nvidia" ;;
    "NVIDIA    - NVIDIA 製 GPU（オープンソース版 Nouveau）")            CONFIG[gpu_driver]="nouveau" ;;
    "AMD       - AMD 製 GPU（Radeon など）")                            CONFIG[gpu_driver]="amdgpu" ;;
    "Intel     - Intel 内蔵グラフィックス（CPU 内蔵グラフィック）")     CONFIG[gpu_driver]="intel" ;;
    "仮想環境  - VirtualBox・VMware 上で動かしている場合")              CONFIG[gpu_driver]="virtual" ;;
    *)                                                                   CONFIG[gpu_driver]="none" ;;
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
      confirm "一般ユーザーを作成しますか？" || break
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

    # 最初のユーザーをサマリー表示用に記録
    if [[ "${CONFIG[users_count]}" -eq 1 ]]; then
      print_ok "ユーザー追加: ${uname} (sudo: ${usudo}, shell: ${ushell})"
    fi
  done

  # ユーザー一覧を表示
  if [[ "${CONFIG[users_count]}" -gt 0 ]]; then
    echo ""
    print_ok "作成予定ユーザー一覧:"
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      parse_users_line "$entry"
      echo -e "    ${CYAN}•${RESET} ${uname}  sudo: ${usudo}  shell: ${ushell}"
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

  local boot_mode="${CONFIG[boot_mode]}"

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
    "Hyprland    - アニメーション・タイル型・Wayland（上級者向け）" \
    "Niri        - スクロール型タイル・Wayland（上級者向け）")

  case "$de" in
    "なし（最小構成・CLI）")                      CONFIG[desktop]="none" ;;
    "KDE Plasma  - 高機能・Wayland/X11")          CONFIG[desktop]="kde" ;;
    "GNOME       - シンプル・Wayland 推奨")        CONFIG[desktop]="gnome" ;;
    "Xfce        - 軽量・X11 安定")               CONFIG[desktop]="xfce" ;;
    "Budgie      - エレガント・Wayland 専用")       CONFIG[desktop]="budgie" ;;
    "COSMIC      - 新世代・Rust 製・Wayland")       CONFIG[desktop]="cosmic" ;;
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
      dm=$(select_from_list "ディスプレイマネージャー (DM) を選択:" \
        "SDDM       - KDE 推奨・Wayland/X11（推奨）" \
        "GDM        - GNOME 製・Wayland 対応" \
        "LightDM    - 軽量・X11/Wayland" \
        "greetd     - 最軽量・TUI" \
        "なし       - TTY から手動起動")
      ;;
    gnome|budgie)
      dm=$(select_from_list "ディスプレイマネージャー (DM) を選択:" \
        "GDM        - GNOME 推奨・Wayland 対応（推奨）" \
        "SDDM       - 軽量・Wayland/X11" \
        "LightDM    - 軽量・X11/Wayland" \
        "greetd     - 最軽量・TUI" \
        "なし       - TTY から手動起動")
      ;;
    xfce)
      dm=$(select_from_list "ディスプレイマネージャー (DM) を選択:" \
        "LightDM    - Xfce 推奨・軽量（推奨）" \
        "SDDM       - 軽量・Wayland/X11" \
        "GDM        - GNOME 製・Wayland 対応" \
        "greetd     - 最軽量・TUI" \
        "なし       - TTY から手動起動")
      ;;
    cosmic)
      dm=$(select_from_list "ディスプレイマネージャー (DM) を選択:" \
        "cosmic-greeter - COSMIC 専用グリーター（推奨）" \
        "GDM            - GNOME 製・Wayland 対応" \
        "SDDM           - 軽量・Wayland/X11" \
        "greetd         - 最軽量・TUI" \
        "なし           - TTY から手動起動")
      ;;
    hyprland|niri)
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

  # 日本語環境専用: 日本語表示に必須のフォントを自動インストール
  local pkgs=(noto-fonts noto-fonts-cjk noto-fonts-emoji)
  print_ok "日本語フォントを自動インストール:"
  echo -e "    ${GRAY}• noto-fonts（欧文）/ noto-fonts-cjk（日本語）/ noto-fonts-emoji（絵文字）${RESET}"

  echo ""
  # 高品質フォント（Adobe 源ノ）を任意で追加（既定 Yes）
  if confirm_yes "高品質な日本語フォント（源ノ角ゴシック・源ノ明朝）も追加しますか？（推奨）"; then
    pkgs+=(adobe-source-han-sans-jp-fonts adobe-source-han-serif-jp-fonts)
    print_ok "源ノ角ゴシック + 源ノ明朝 を追加"
  fi

  # プログラミング向け等幅フォント（既定 No）
  if confirm "プログラミング向け等幅フォント Fira Code も追加しますか？"; then
    pkgs+=(ttf-fira-code)
    print_ok "ttf-fira-code を追加"
  fi

  CONFIG[font_pkgs]="${pkgs[*]}"
  CONFIG[font_setup_fontconfig]="yes"
  echo ""
  print_ok "インストール予定フォント: ${CONFIG[font_pkgs]}"
  print_ok "fontconfig: 日本語・絵文字の優先度を自動設定します"
}

# ============================================
# ステップ 7: 追加パッケージ
# ============================================

step_extra_packages() {
  print_step "追加パッケージ・サービス"

  echo -e "  日本語環境向けの推奨設定です。${GREEN}Enter でそのまま有効化${RESET}できます。\n"

  # zram（圧縮RAMスワップ）
  if confirm_yes "zram を有効にしますか？（RAM 上の圧縮スワップ・推奨）"; then
    CONFIG[extra_zram]="yes"; print_ok "zram を有効化"
  else
    CONFIG[extra_zram]="no"; print_ok "zram はスキップ"
  fi

  # OpenSSH サーバー
  if confirm_yes "OpenSSH サーバーをインストール・有効化しますか？（リモート接続用・推奨）"; then
    CONFIG[extra_ssh]="yes"; print_ok "OpenSSH を有効化（sshd を自動起動）"
  else
    CONFIG[extra_ssh]="no"; print_ok "OpenSSH はスキップ"
  fi

  # fstrim.timer（SSD の定期 TRIM）
  if confirm_yes "SSD 向けの定期 TRIM（fstrim.timer）を有効にしますか？（推奨）"; then
    CONFIG[extra_fstrim]="yes"; print_ok "fstrim.timer を有効化"
  else
    CONFIG[extra_fstrim]="no"; print_ok "fstrim.timer はスキップ"
  fi

  # Google Chrome（AUR）— base-devel + AUR ヘルパーを自動で連動有効化
  if confirm_yes "Google Chrome をインストールしますか？（AUR・推奨）"; then
    CONFIG[install_chrome]="yes"
    CONFIG[extra_base_devel]="yes"
    [[ "${CONFIG[aur_helper]}" == "none" ]] && CONFIG[aur_helper]="yay"
    print_ok "Google Chrome をインストール（base-devel + ${CONFIG[aur_helper]} を自動有効化）"
  else
    CONFIG[install_chrome]="no"; print_ok "Google Chrome はスキップ"
  fi

  # yt-fzf-sh（GitHub の PKGBUILD・fzf/yt-dlp を使う対話的 YouTube ツール）
  if confirm_yes "yt-fzf-sh をインストールしますか？（fzf/yt-dlp の YouTube ダウンローダ・推奨）"; then
    CONFIG[install_ytfzf]="yes"
    CONFIG[extra_base_devel]="yes"   # makepkg に base-devel が必要
    print_ok "yt-fzf-sh をインストール（コマンド: yt-fzf）"
  else
    CONFIG[install_ytfzf]="no"; print_ok "yt-fzf-sh はスキップ"
  fi

  # AUR ヘルパー（Chrome を入れない場合のみ個別に確認）
  if [[ "${CONFIG[install_chrome]}" != "yes" ]]; then
    if confirm_yes "AUR ヘルパー（yay）をインストールしますか？（AUR パッケージ導入用・推奨）"; then
      CONFIG[extra_base_devel]="yes"
      local helper
      helper=$(select_from_list "AUR ヘルパーを選択:" \
        "yay  - Go 製・人気 No.1（推奨）" \
        "paru - Rust 製・高機能")
      case "$helper" in
        "yay"*)  CONFIG[aur_helper]="yay" ;;
        "paru"*) CONFIG[aur_helper]="paru" ;;
      esac
      print_ok "AUR ヘルパー: ${CONFIG[aur_helper]}"
    else
      CONFIG[aur_helper]="none"
      # yt-fzf 用に base-devel が必要な場合は無効化しない
      [[ "${CONFIG[install_ytfzf]:-no}" == "yes" ]] || CONFIG[extra_base_devel]="no"
      print_ok "AUR ヘルパーはスキップ"
    fi
  fi

  # ufw（任意・既定 No）— SSH と併用する場合は 22 番ポートを自動許可
  if confirm "ufw（ファイアウォール）を有効にしますか？"; then
    CONFIG[extra_ufw]="yes"; print_ok "ufw を有効化"
  else
    CONFIG[extra_ufw]="no"
  fi

  # その他の追加パッケージ
  local extra
  extra=$(ask "その他の追加パッケージ（スペース区切り、不要なら空 Enter）" "")
  CONFIG[extra_pkgs]="$extra"
  [[ -n "$extra" ]] && print_ok "追加パッケージ: $extra"
}

# ============================================
# 設定サマリー表示
# ============================================

show_summary() {
  print_step "インストール設定サマリー"

  echo -e "  ${BOLD}ディスク      :${RESET} ${CONFIG[disk]}"
  echo -e "  ${BOLD}パーティション :${RESET} ${CONFIG[partition_scheme]}"
  echo -e "  ${BOLD}ファイルシステム:${RESET} ${CONFIG[fs_type]}"
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
  echo -e "  ${BOLD}Google Chrome :${RESET} ${CONFIG[install_chrome]:-no}"
  echo -e "  ${BOLD}yt-fzf-sh     :${RESET} ${CONFIG[install_ytfzf]:-no}"
  echo -e "  ${BOLD}OpenSSH       :${RESET} ${CONFIG[extra_ssh]}"
  echo -e "  ${BOLD}ufw (FW)      :${RESET} ${CONFIG[extra_ufw]}"
  echo -e "  ${BOLD}zram          :${RESET} ${CONFIG[extra_zram]}"
  echo -e "  ${BOLD}fstrim.timer  :${RESET} ${CONFIG[extra_fstrim]:-no}"
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
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      parse_users_line "$entry"
      echo -e "    ${CYAN}•${RESET} ${uname}  sudo: ${usudo}  shell: ${ushell}"
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

  # 対象ディスクのパーティションが既にマウントされていれば全てアンマウント
  run_cmd "既存マウントの解除" bash -c "
    for mp in \$(lsblk -lno MOUNTPOINT '${disk}' 2>/dev/null | grep -v '^$' | sort -r); do
      umount -f \"\$mp\" 2>/dev/null || true
    done
    swapoff -a 2>/dev/null || true
  "

  # GPT で全消去（--zap-all は GPT/MBR 双方を破棄し、以降の --new で新規GPTが作られる）
  run_cmd "GPT テーブル初期化" sgdisk --zap-all "$disk"

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
  # partprobe だけでは不十分な場合があるため複数手段を使う
  run_cmd "パーティションテーブル再読込 (partprobe)" partprobe "$disk"
  # blockdev --rereadpt はビジー状態でエラーになることがあるため無視
  blockdev --rereadpt "$disk" 2>/dev/null || true
  udevadm settle 2>/dev/null || true
  sleep 1

  # パーティションデバイスが実際に存在するまで最大30秒待機
  local first_part
  first_part=$(part_suffix "$disk" 1)
  local waited=0
  while [[ ! -b "$first_part" ]] && [[ "$waited" -lt 30 ]]; do
    sleep 1
    waited=$(( waited + 1 ))
    # 5秒経っても認識されなければ再度 partprobe を試みる
    if [[ "$waited" -eq 5 ]]; then
      partprobe "$disk" 2>/dev/null || true
      udevadm settle 2>/dev/null || true
    fi
  done
  if [[ ! -b "$first_part" ]]; then
    echo "エラー: パーティション ($first_part) がカーネルに認識されませんでした。" >> "${CONFIG[log_file]}"
    echo "--- dmesg ---" >> "${CONFIG[log_file]}"
    dmesg | tail -20 >> "${CONFIG[log_file]}" 2>/dev/null || true
    echo "--- lsblk ---" >> "${CONFIG[log_file]}"
    lsblk >> "${CONFIG[log_file]}" 2>/dev/null || true
    print_err "パーティション ($first_part) がカーネルに認識されませんでした。"
    print_err "ログを確認してください: ${CONFIG[log_file]}"
    exit 1
  fi
  print_ok "パーティションをカーネルが認識しました (${waited}秒待機)"
}

# ============================================
# ユーティリティ: ルートパーティションをフォーマット
# CONFIG[fs_type] に応じて適切な mkfs を呼ぶ
# ============================================

_format_root() {
  local part="$1"
  local fs="${CONFIG[fs_type]:-ext4}"
  case "$fs" in
    ext4)  run_cmd "root フォーマット (ext4)"  mkfs.ext4  -F "$part" ;;
    btrfs) run_cmd "root フォーマット (btrfs)" mkfs.btrfs -f "$part" ;;
    xfs)   run_cmd "root フォーマット (xfs)"   mkfs.xfs   -f "$part" ;;
    *)     run_cmd "root フォーマット (ext4)"  mkfs.ext4  -F "$part" ;;
  esac
}

_mount_root() {
  local part="$1"
  local fs="${CONFIG[fs_type]:-ext4}"

  # フォーマット直後にデバイスが準備完了するまで待機（失敗しても続行）
  udevadm settle 2>/dev/null || true
  sleep 1

  case "$fs" in
    btrfs)
      # btrfs: まずサブボリューム作成のために一時マウント
      run_cmd "btrfs 一時マウント" mount -t btrfs "$part" /mnt

      # @, @home, @log, @cache サブボリュームを作成
      run_cmd "btrfs サブボリューム @ 作成"    btrfs subvolume create /mnt/@
      run_cmd "btrfs サブボリューム @home 作成" btrfs subvolume create /mnt/@home
      run_cmd "btrfs サブボリューム @log 作成"  btrfs subvolume create /mnt/@log
      run_cmd "btrfs サブボリューム @cache 作成" btrfs subvolume create /mnt/@cache

      # 一時マウントを解除して正式にサブボリュームでマウント
      run_cmd "btrfs 一時アンマウント" umount /mnt

      local btrfs_opts="compress=zstd,noatime,space_cache=v2"
      run_cmd "root マウント (btrfs @)" \
        mount -t btrfs -o "${btrfs_opts},subvol=@" "$part" /mnt

      run_cmd "/home ディレクトリ作成" mkdir -p /mnt/home
      run_cmd "home マウント (btrfs @home)" \
        mount -t btrfs -o "${btrfs_opts},subvol=@home" "$part" /mnt/home

      run_cmd "/var/log ディレクトリ作成" mkdir -p /mnt/var/log
      run_cmd "log マウント (btrfs @log)" \
        mount -t btrfs -o "${btrfs_opts},subvol=@log" "$part" /mnt/var/log

      run_cmd "/var/cache ディレクトリ作成" mkdir -p /mnt/var/cache
      run_cmd "cache マウント (btrfs @cache)" \
        mount -t btrfs -o "${btrfs_opts},subvol=@cache" "$part" /mnt/var/cache
      ;;
    xfs)
      run_cmd "root マウント (xfs)" mount -t xfs "$part" /mnt
      ;;
    *)
      run_cmd "root マウント (ext4)" mount -t ext4 "$part" /mnt
      ;;
  esac
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
      lsblk -p "$disk" 2>/dev/null || fdisk -l "$disk" 2>/dev/null || ls /sys/block/${disk#/dev/}/ || true
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
        _format_root "$root_p"
      fi
      _mount_root "$root_p"

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
        run_cmd "EFI マウント" mount -t vfat "$efi_p" /mnt/boot
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

    echo "[DEBUG] EFI フォーマット開始: $efi_part" >> "${CONFIG[log_file]}"
    run_cmd "EFI フォーマット (FAT32)"  mkfs.fat -F32 "$efi_part"
    echo "[DEBUG] root フォーマット開始: $root_part (fs=${CONFIG[fs_type]})" >> "${CONFIG[log_file]}"
    _format_root "$root_part"
    echo "[DEBUG] _format_root 完了" >> "${CONFIG[log_file]}"
    [[ -n "$swap_part" ]] && run_cmd "swap フォーマット" mkswap "$swap_part"
    echo "[DEBUG] _mount_root 開始: $root_part" >> "${CONFIG[log_file]}"
    _mount_root "$root_part"
    echo "[DEBUG] _mount_root 完了" >> "${CONFIG[log_file]}"
    run_cmd "EFI ディレクトリ作成" mkdir -p /mnt/boot
    echo "[DEBUG] EFI マウント開始: $efi_part" >> "${CONFIG[log_file]}"
    run_cmd "EFI マウント" mount -t vfat "$efi_part" /mnt/boot
    echo "[DEBUG] EFI マウント完了" >> "${CONFIG[log_file]}"
    [[ -n "$swap_part" ]] && run_cmd "swap 有効化" swapon "$swap_part" || true

  else
    # BIOS（efi_part/swap_part/root_part は関数先頭で local 宣言済み）
    if [[ "$scheme" == "auto_swap" ]]; then
      swap_part=$(part_suffix "$disk" 2)
      root_part=$(part_suffix "$disk" 3)
    else
      root_part=$(part_suffix "$disk" 2)
    fi

    _format_root "$root_part"
    [[ -n "$swap_part" ]] && run_cmd "swap フォーマット" mkswap "$swap_part" || true

    _mount_root "$root_part"
    [[ -n "$swap_part" ]] && run_cmd "swap 有効化" swapon "$swap_part" || true
  fi
}

# ============================================
# ネットワーク疎通確認
# ============================================

step_check_network() {
  print_step "ネットワーク確認"
  echo -ne "  ${CYAN}…${RESET} インターネット接続を確認中..."
  # ICMP を遮断する環境があるため、ping が失敗しても HTTPS 疎通を確認する
  if ping -c1 -W3 archlinux.org &>/dev/null || curl -sf -m5 https://archlinux.org -o /dev/null; then
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
    if ping -c1 -W5 archlinux.org &>/dev/null || curl -sf -m8 https://archlinux.org -o /dev/null; then
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
    "iwd（軽量・高速・推奨）" \
    "wpa_supplicant（古くから使われている実装・互換性重視）" \
    "なし（有線のみ・後から設定）")

  case "$wifi_backend" in
    "iwd（軽量・高速・推奨）")                              CONFIG[wifi_backend]="iwd" ;;
    "wpa_supplicant（古くから使われている実装・互換性重視）") CONFIG[wifi_backend]="wpa_supplicant" ;;
    "なし（有線のみ・後から設定）")                          CONFIG[wifi_backend]="none" ;;
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
        run_cmd_retry "reflector インストール" pacman -S --noconfirm reflector
      fi

      # 国名は "United States" のように空白を含むことがあるため、
      # 単語分割で壊れないよう配列で渡す（未クォート展開だと reflector がエラー終了する）
      local reflector_args=(
        --protocol https
        --age 24
        --sort rate
        --number 8
        --save /etc/pacman.d/mirrorlist
      )
      if [[ -n "${CONFIG[mirror_country]:-}" ]]; then
        reflector_args=(--country "${CONFIG[mirror_country]}" "${reflector_args[@]}")
      fi

      local country_disp="${CONFIG[mirror_country]:-全世界}"
      # 指定のミラーから HTTPS・最終同期24時間以内・速度順 上位8件
      run_cmd_retry "reflector 実行（${country_disp}・速度順）" \
        reflector "${reflector_args[@]}"
      print_ok "選択されたミラー:"
      grep '^Server' /etc/pacman.d/mirrorlist | sed 's/^/    /' || true
      ;;

    manual)
      local host="${CONFIG[mirror_host]}"
      run_cmd "ミラーリスト書き込み" bash -c "cat > /etc/pacman.d/mirrorlist << EOF
# 手動選択: ${host}
Server = https://${host}/archlinux/\\\$repo/os/\\\$arch
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

  # pacman キーリング初期化（Live ISO では既に初期化済みの場合はスキップ）
  if [[ ! -f /etc/pacman.d/gnupg/trustdb.gpg ]]; then
    run_cmd "pacman キーリング初期化" pacman-key --init
  else
    print_ok "pacman キーリング初期化済み（スキップ）"
  fi
  run_cmd "Arch キーリング追加" pacman-key --populate archlinux
  # Live ISOのキーリングを最新化（署名エラー防止）
  run_cmd_retry "Live ISO キーリング更新" pacman -Sy --noconfirm archlinux-keyring
  # パッケージデータベースを強制再取得（-Sy だと古いDBで部分アップグレードが起きる恐れがある）
  run_cmd_retry "パッケージDB更新" pacman -Syy --noconfirm

  local pkgs=(base sudo linux linux-firmware sof-firmware networkmanager vim)

  # ファイルシステム固有パッケージ
  case "${CONFIG[fs_type]:-ext4}" in
    btrfs) pkgs+=(btrfs-progs); print_ok "ファイルシステム用 btrfs-progs を追加" ;;
    xfs)   pkgs+=(xfsprogs);    print_ok "ファイルシステム用 xfsprogs を追加" ;;
  esac

  # WiFi バックエンド
  case "${CONFIG[wifi_backend]}" in
    wpa_supplicant) pkgs+=(wpa_supplicant) ;;
    iwd)            pkgs+=(iwd) ;;
  esac

  # マイクロコード
  local cpu_vendor="${CONFIG[cpu_vendor]}"
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
    # Windows デュアルブート時は他OS検出のため os-prober / ntfs-3g を追加
    if [[ "${CONFIG[dualboot_windows]}" == "yes" ]]; then
      pkgs+=(os-prober ntfs-3g)
      print_ok "デュアルブート用に os-prober を追加"
    fi
  fi

  # AURヘルパー/Chrome/yt-fzf 用 git の追加（いずれも clone + makepkg を使う）
  if [[ "${CONFIG[aur_helper]}" != "none" || "${CONFIG[install_chrome]:-no}" == "yes" || "${CONFIG[install_ytfzf]:-no}" == "yes" ]]; then
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
    intel)
      # xf86-video-intel は X11 専用。Wayland DE では mesa + vulkan-intel のみで十分
      local is_wayland_de="no"
      case "${CONFIG[desktop]}" in
        gnome|kde|hyprland|niri|cosmic|budgie) is_wayland_de="yes" ;;
      esac
      if [[ "$is_wayland_de" == "yes" ]]; then
        pkgs+=(mesa vulkan-intel)
        print_ok "Intel GPU (Wayland): mesa + vulkan-intel（xf86-video-intel はスキップ）"
      else
        pkgs+=(xf86-video-intel mesa vulkan-intel)
      fi
      ;;
    virtual) pkgs+=(xf86-video-vmware) ;;
  esac

  # 仮想環境ゲストツールの追加
  case "${CONFIG[virt_env]}" in
    oracle)             pkgs+=(virtualbox-guest-utils) ;;
    kvm|qemu)           pkgs+=(qemu-guest-agent) ;;
    vmware)             pkgs+=(open-vm-tools) ;;
  esac

  # ユーザーが選択した追加パッケージ
  # base-devel は makepkg に必須。AUR/Chrome/yt-fzf のいずれかがあれば必ず入れる。
  if [[ "${CONFIG[extra_base_devel]}" == "yes" \
        || "${CONFIG[aur_helper]}" != "none" \
        || "${CONFIG[install_chrome]:-no}" == "yes" \
        || "${CONFIG[install_ytfzf]:-no}" == "yes" ]]; then
    pkgs+=(base-devel)
  fi
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

  # 日本語環境が有効なのに CJK フォントが無い場合、文字化け（豆腐）を防ぐため
  # 最低限の日本語・絵文字フォントを自動追加する（初心者救済のセーフティネット）
  if [[ "${CONFIG[japanese_env]}" == "yes" ]]; then
    [[ " ${pkgs[*]} " == *" noto-fonts-cjk "* ]]   || { pkgs+=(noto-fonts-cjk);   print_ok "日本語表示のため noto-fonts-cjk を自動追加（豆腐防止）"; }
    [[ " ${pkgs[*]} " == *" noto-fonts "* ]]       || pkgs+=(noto-fonts)
    [[ " ${pkgs[*]} " == *" noto-fonts-emoji "* ]] || pkgs+=(noto-fonts-emoji)
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

  run_cmd_retry "pacstrap 実行（時間がかかります）" pacstrap /mnt "${pkgs[@]}"
}
do_fstab() {
  print_step "fstab 生成"
  run_cmd "fstab 生成" bash -c "genfstab -U /mnt > /mnt/etc/fstab"
  print_ok "生成内容:"
  sed 's/^/    /' /mnt/etc/fstab
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
    # adjtime の3行目を LOCAL に確実に上書き（>> だと二重追記になるため > で書き直す）
    run_cmd "adjtime LOCAL 設定" bash -c \
      "printf '0.0 0 0.0\n0\nLOCAL\n' > /mnt/etc/adjtime"
  else
    # 通常: RTC を UTC として扱う（推奨）
    run_cmd "RTC UTC 設定" arch-chroot /mnt hwclock --systohc --utc
  fi

  # systemd-timesyncd を有効化（インストール後も NTP 同期を維持）
  run_cmd "systemd-timesyncd 有効化" \
    systemctl --root=/mnt enable systemd-timesyncd

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

  # 全ログインセッション（DM/TTY問わず pam_env が読む）で LANG を保証する。
  # /etc/locale.conf だけだと、軽量セッション（niri/Hyprland を greetd 等で起動）で
  # LANG が渡らず、漢字が中国語字形になることがあるため、二重に明示しておく。
  if [[ "${CONFIG[japanese_env]}" == "yes" ]]; then
    run_cmd "LANG を /etc/environment にも設定（全DE共通）" bash -c "
      grep -q '^LANG=' /mnt/etc/environment 2>/dev/null || echo 'LANG=${CONFIG[locale]}' >> /mnt/etc/environment
      grep -q '^LC_CTYPE=' /mnt/etc/environment 2>/dev/null || echo 'LC_CTYPE=${CONFIG[locale]}' >> /mnt/etc/environment
    "
  fi

  run_cmd "キーマップ設定" \
    bash -c "echo 'KEYMAP=${CONFIG[keymap]}' > /mnt/etc/vconsole.conf"

  # X11 キーボードレイアウト設定
  local xkb_layout="us"
  local xkb_model=""
  case "${CONFIG[keymap]}" in
    jp106) xkb_layout="jp"; xkb_model="jp106" ;;
    uk)    xkb_layout="gb" ;;
    us)    xkb_layout="us" ;;
    *)     xkb_layout="${CONFIG[keymap]}" ;;
  esac

  if [[ -n "$xkb_layout" && "$xkb_layout" != "none" ]]; then
    run_cmd "X11 キーマップ設定" bash -c "
      mkdir -p /mnt/etc/X11/xorg.conf.d
      {
        echo 'Section \"InputClass\"'
        echo '        Identifier \"system-keyboard\"'
        echo '        MatchIsKeyboard \"on\"'
        echo \"        Option \\\"XkbLayout\\\" \\\"${xkb_layout}\\\"\"
        [[ -n \"${xkb_model}\" ]] && echo \"        Option \\\"XkbModel\\\" \\\"${xkb_model}\\\"\"
        echo 'EndSection'
      } > /mnt/etc/X11/xorg.conf.d/00-keyboard.conf
    "
  fi

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
    systemctl --root=/mnt enable NetworkManager

  # WiFi バックエンド設定
  case "${CONFIG[wifi_backend]}" in
    iwd)
      run_cmd "iwd 有効化" systemctl --root=/mnt enable iwd
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
        systemctl --root=/mnt enable wpa_supplicant
      print_ok "NetworkManager → wpa_supplicant バックエンド（デフォルト）"
      ;;
  esac

  # systemd-resolved 設定
  if [[ "${CONFIG[use_resolved]}" == "yes" ]]; then
    run_cmd "systemd-resolved 有効化" \
      systemctl --root=/mnt enable systemd-resolved
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
    local is_wayland="no"
    case "${CONFIG[desktop]}" in
      gnome|kde|hyprland|niri|cosmic|budgie) is_wayland="yes" ;;
    esac

    # Wayland上でIMモジュールの自動解決に対応しているフルDE（GNOME/KDE/COSMIC）かどうか判定
    # wlroots系のHyprland/Niriでは環境変数の明示が必要
    local is_wayland_de_native="no"
    case "${CONFIG[desktop]}" in
      gnome|kde|cosmic|budgie) is_wayland_de_native="yes" ;;
    esac

    case "${CONFIG[jp_ime]}" in
      fcitx5-mozc|fcitx5-anthy)
        if [[ "$is_wayland" == "yes" && "$is_wayland_de_native" == "yes" ]]; then
          # GNOME/KDE/COSMIC Wayland: GTK/QT の IM MODULE は設定しない
          # text-input-v3 プロトコルを DE が処理する
          run_cmd "fcitx5 環境変数設定 (Wayland Native DE)" bash -c "cat >> /mnt/etc/environment << 'EOF'
# fcitx5 - Wayland Native DE
# GTK_IM_MODULE / QT_IM_MODULE は意図的に未設定
# (GTK3/4 は text-input-v3、Qt は DE の virtual keyboard を使用)
XMODIFIERS=@im=fcitx
SDL_IM_MODULE=fcitx
EOF"
          if [[ "${CONFIG[desktop]}" == "kde" ]]; then
            print_warn "KDE: システム設定 → 仮想キーボード → Fcitx5 を選択してください"
          fi
        else
          # X11 または Hyprland/Niri (wlroots WMs): GTK_IM_MODULE / QT_IM_MODULE / XMODIFIERS を全て設定
          run_cmd "fcitx5 環境変数設定 (X11 / wlroots WM)" bash -c "cat >> /mnt/etc/environment << 'EOF'
# fcitx5 - X11 / wlroots WM
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
SDL_IM_MODULE=fcitx
EOF"
        fi
        ;;
      ibus-mozc)
        if [[ "$is_wayland" == "yes" && "$is_wayland_de_native" == "yes" ]]; then
          run_cmd "ibus 環境変数設定 (Wayland Native DE)" bash -c "cat >> /mnt/etc/environment << 'EOF'
# ibus - Wayland Native DE
XMODIFIERS=@im=ibus
EOF"
        else
          run_cmd "ibus 環境変数設定 (X11 / wlroots WM)" bash -c "cat >> /mnt/etc/environment << 'EOF'
# ibus - X11 / wlroots WM
GTK_IM_MODULE=ibus
QT_IM_MODULE=ibus
XMODIFIERS=@im=ibus
EOF"
        fi
        ;;
    esac

    # Fcitx5 の初期設定プロファイルを生成（初回起動時から日本語入力・Mozcを使えるようにする）
    if [[ "${CONFIG[jp_ime]}" =~ ^fcitx5 ]]; then
      local layout="jp"
      local kb_item="keyboard-jp"
      if [[ "${CONFIG[keymap]}" == "us" ]]; then
        layout="us"
        kb_item="keyboard-us"
      elif [[ "${CONFIG[keymap]}" == "uk" ]]; then
        layout="gb"
        kb_item="keyboard-gb"
      fi

      run_cmd "Fcitx5 プロファイル初期設定" bash -c "
        mkdir -p /mnt/etc/skel/.config/fcitx5
        cat > /mnt/etc/skel/.config/fcitx5/profile << EOF
[Groups/0]
Name=Default
Default Layout=${layout}
DefaultIM=mozc

[Groups/0/Items/0]
Name=${kb_item}
Layout=

[Groups/0/Items/1]
Name=mozc
Layout=
EOF
      "
      print_ok "Fcitx5: 日本語入力の初期レイアウト・Mozcを設定しました"
    fi

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
  <!-- ターミナル(alacritty 等)の漢字が中国語字形(SC)になるのを防ぐ。 -->
  <!-- 等幅フォントの CJK フォールバックに 日本語字形(JP) を強制的に付加する。 -->
  <!-- prefer だけでは per-glyph フォールバックで SC が選ばれることがあるため match を併用。 -->
  <match target=\"pattern\">
    <test name=\"family\"><string>monospace</string></test>
    <edit name=\"family\" mode=\"append\" binding=\"strong\"><string>Noto Sans Mono CJK JP</string></edit>
  </match>
  <match target=\"pattern\">
    <test name=\"family\"><string>JetBrainsMono Nerd Font</string></test>
    <edit name=\"family\" mode=\"append\" binding=\"strong\"><string>Noto Sans Mono CJK JP</string></edit>
  </match>
  <match target=\"pattern\">
    <test name=\"family\"><string>JetBrains Mono</string></test>
    <edit name=\"family\" mode=\"append\" binding=\"strong\"><string>Noto Sans Mono CJK JP</string></edit>
  </match>
  <match target=\"pattern\">
    <test name=\"family\"><string>Fira Code</string></test>
    <edit name=\"family\" mode=\"append\" binding=\"strong\"><string>Noto Sans Mono CJK JP</string></edit>
  </match>
</fontconfig>
EOF"
    print_ok "fontconfig: 絵文字・日本語・Fira の優先度を設定しました"
  fi

  # pacman.conf の最適化
  run_cmd "pacman.conf チューニング（インストール先）" \
    bash -c "$(declare -f tune_pacman_conf); tune_pacman_conf /mnt/etc/pacman.conf"

  # ハイバネート用の resume フック追加
  if [[ "${CONFIG[partition_scheme]}" == "auto_swap" ]]; then
    run_cmd "mkinitcpio.conf に resume フックを追加" bash -c "
      if grep -q '^HOOKS=' /mnt/etc/mkinitcpio.conf; then
        sed -i 's/\bfilesystems\b/resume filesystems/' /mnt/etc/mkinitcpio.conf
      fi
    "
  fi

  # btrfs モジュール追加
  if [[ "${CONFIG[fs_type]}" == "btrfs" ]]; then
    run_cmd "mkinitcpio.conf に btrfs モジュールを追加" bash -c "
      if grep -q '^MODULES=()' /mnt/etc/mkinitcpio.conf; then
        sed -i 's/^MODULES=()/MODULES=(btrfs)/' /mnt/etc/mkinitcpio.conf
      elif grep -q '^MODULES=' /mnt/etc/mkinitcpio.conf; then
        sed -i 's/^MODULES=(\(.*\))/MODULES=(\1 btrfs)/' /mnt/etc/mkinitcpio.conf
      fi
    "
  fi

  # NVIDIA KMS 設定
  if [[ "${CONFIG[gpu_driver]}" == "nvidia" ]]; then
    run_cmd "mkinitcpio.conf に NVIDIA モジュールを追加" bash -c "
      if grep -q '^MODULES=' /mnt/etc/mkinitcpio.conf; then
        # MODULES=() の場合と MODULES=(既存) の場合を分けて処理
        if grep -q '^MODULES=()' /mnt/etc/mkinitcpio.conf; then
          sed -i 's/^MODULES=()/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /mnt/etc/mkinitcpio.conf
        else
          sed -i 's/^MODULES=(\(.*\))/MODULES=(\1 nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /mnt/etc/mkinitcpio.conf
        fi
      fi
    "
  fi

  # 各種サービスの有効化

  if [[ "${CONFIG[extra_ssh]}" == "yes" ]]; then
    run_cmd "OpenSSH サービス有効化" systemctl --root=/mnt enable sshd
  fi

  if [[ "${CONFIG[extra_fstrim]:-no}" == "yes" ]]; then
    run_cmd "fstrim.timer 有効化（SSD 定期 TRIM）" systemctl --root=/mnt enable fstrim.timer
  fi

  if [[ "${CONFIG[extra_ufw]}" == "yes" ]]; then
    # SSH を併用する場合はロックアウト防止のため 22 番ポートを事前許可
    if [[ "${CONFIG[extra_ssh]}" == "yes" ]]; then
      run_cmd "ufw: SSH(22) を許可" arch-chroot /mnt ufw allow ssh
    fi
    run_cmd "UFW サービス有効化" systemctl --root=/mnt enable ufw
  fi

  case "${CONFIG[virt_env]}" in
    oracle)
      run_cmd "VirtualBox Guest サービス有効化" systemctl --root=/mnt enable vboxservice
      ;;
    kvm|qemu)
      run_cmd "QEMU Guest Agent 有効化" systemctl --root=/mnt enable qemu-guest-agent
      ;;
    vmware)
      run_cmd "VMware Tools サービス有効化" systemctl --root=/mnt enable vmtoolsd
      ;;
  esac

  # xdg-user-dirs-update の自動実行設定（初回ログイン時にホームディレクトリ群を生成）
  # 選択されたシェルのプロファイルにのみ追記する
  run_cmd "fish スケルディレクトリ作成" mkdir -p /mnt/etc/skel/.config/fish

  # bash が選ばれている場合のみ .bash_profile に追記
  if echo "${CONFIG[users]}" | grep -q '|bash|'; then
    run_cmd "bash xdg-user-dirs-update 設定" bash -c "cat >> /mnt/etc/skel/.bash_profile << 'EOF'

# 初回ログイン時にユーザーディレクトリを自動作成
if [ -x /usr/bin/xdg-user-dirs-update ]; then
  xdg-user-dirs-update
fi
EOF"
  fi

  # zsh が選ばれている場合のみ .zprofile に追記
  if echo "${CONFIG[users]}" | grep -q '|zsh|'; then
    run_cmd "zsh xdg-user-dirs-update 設定" bash -c "cat >> /mnt/etc/skel/.zprofile << 'EOF'

# 初回ログイン時にユーザーディレクトリを自動作成
if [ -x /usr/bin/xdg-user-dirs-update ]; then
  xdg-user-dirs-update
fi
EOF"
  fi

  # fish が選ばれている場合のみ config.fish に追記
  if echo "${CONFIG[users]}" | grep -q '|fish|'; then
    run_cmd "fish xdg-user-dirs-update 設定" bash -c "cat >> /mnt/etc/skel/.config/fish/config.fish << 'EOF'

# 初回ログイン時にユーザーディレクトリを自動作成
if test -x /usr/bin/xdg-user-dirs-update
  xdg-user-dirs-update
end
EOF"
  fi

  # Chromium / Electron 系アプリの Wayland / IME 連携設定
  if [[ "${CONFIG[desktop]}" != "none" ]]; then
    run_cmd "Chromium/Electron 向け Wayland IME 連携設定" bash -c "
      mkdir -p /mnt/etc/skel/.config
      cat > /mnt/etc/skel/.config/chrome-flags.conf << 'EOF'
--ozone-platform-hint=auto
--enable-wayland-ime
EOF
      cp /mnt/etc/skel/.config/chrome-flags.conf /mnt/etc/skel/.config/chromium-flags.conf
      cp /mnt/etc/skel/.config/chrome-flags.conf /mnt/etc/skel/.config/electron-flags.conf
      cp /mnt/etc/skel/.config/chrome-flags.conf /mnt/etc/skel/.config/code-flags.conf
    "
  fi

  # initramfs の再生成
  run_cmd "initramfs 再生成 (mkinitcpio)" arch-chroot /mnt mkinitcpio -P
}

# ============================================
# 実行: ユーザー設定
# ============================================

do_users() {
  print_step "ユーザー設定"

  local entry
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    parse_users_line "$entry"

    local shell_path="/bin/bash"
    case "$ushell" in
      zsh)  shell_path="/bin/zsh" ;;
      fish) shell_path="/bin/fish" ;;
    esac

    run_cmd "ユーザー作成: ${uname}" \
      arch-chroot /mnt useradd -m -G "$ugroups" -s "$shell_path" "$uname"

    _set_password "$uname" "$upw"
    upw=""  # メモリ上の平文パスワードをクリア

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
    CONFIG[root_password]=""  # メモリ上の平文パスワードをクリア
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

  if [[ "$scheme" == "manual" ]]; then
    # 手動パーティション時はパーティション番号が不定なのでユーザーに確認
    print_warn "手動パーティションモードのため、ブートローダー用にパーティションを確認します。"
    lsblk -p "$disk" 2>/dev/null || fdisk -l "$disk" 2>/dev/null || ls /sys/block/${disk#/dev/}/ || true
    while true; do
      root_part=$(ask "Root (/) パーティションのデバイスパス（例: /dev/sda2）")
      [[ -b "$root_part" ]] && break
      print_err "有効なブロックデバイスではありません: $root_part"
    done

    # manual 時も swap の有無をユーザーに確認する
    local swap_input
    swap_input=$(ask "Swap パーティションのデバイスパス（不要なら空 Enter）" "")
    if [[ -n "$swap_input" ]]; then
      if [[ -b "$swap_input" ]]; then
        swap_part="$swap_input"
      else
        print_warn "有効なデバイスではないため swap はスキップします: $swap_input"
      fi
    fi
  elif [[ "$scheme" == "auto_swap" ]]; then
    swap_part=$(part_suffix "$disk" 2)
    root_part=$(part_suffix "$disk" 3)
  else
    root_part=$(part_suffix "$disk" 2)
  fi

  # swap_partuuid 取得 — scheme に関わらず swap_part が設定されていれば取得する
  if [[ -n "$swap_part" ]]; then
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

    local root_partuuid
    if [[ "${CONFIG[dry_run]}" != "yes" ]]; then
      root_partuuid=$(blkid -s PARTUUID -o value "$root_part")
      if [[ -z "$root_partuuid" ]]; then
        print_err "root パーティション ($root_part) の PARTUUID を取得できませんでした。"
        print_err "パーティションが正しくフォーマットされているか確認してください。"
        exit 1
      fi
    else
      root_partuuid="DRY-RUN-ROOT-PARTUUID"
    fi

    # マイクロコードの initrd を判定
    local ucode_initrd=""
    local cpu_vendor="${CONFIG[cpu_vendor]}"
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
      systemctl --root=/mnt enable systemd-boot-update.service

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
      # 先頭スペースを除去してから挿入（CMDLINE が空のとき " resume=..." にならないよう）
      local extra_options_trimmed="${extra_options# }"
      run_cmd "GRUB 設定ファイルにパラメータを追加" bash -c "
        if [[ -f /mnt/etc/default/grub ]]; then
          sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 ${extra_options_trimmed}\"/' /mnt/etc/default/grub
          # CMDLINE が空だった場合の先頭スペースを除去
          sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=\" /GRUB_CMDLINE_LINUX_DEFAULT=\"/' /mnt/etc/default/grub
        fi
      "
    fi

    # Windows 等の他OSを検出してGRUBメニューに追加（os-prober を有効化）
    if [[ "${CONFIG[dualboot_windows]}" == "yes" ]]; then
      run_cmd "GRUB os-prober 有効化（他OS検出）" bash -c "
        if [[ -f /mnt/etc/default/grub ]]; then
          if grep -q '^#\?GRUB_DISABLE_OS_PROBER' /mnt/etc/default/grub; then
            sed -i 's/^#\?GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /mnt/etc/default/grub
          else
            echo 'GRUB_DISABLE_OS_PROBER=false' >> /mnt/etc/default/grub
          fi
        fi
      "
      print_ok "os-prober 有効化: Windows があればメニューに自動追加されます"
    fi

    run_cmd "grub.cfg 生成" \
      arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
  fi
}

# 任意の git リポジトリを clone → makepkg -si する（ユーザー権限・ホーム内・単一セッション）。
# 成功=0 / 失敗=1（非致命的）。呼び出し側で一時 NOPASSWD sudo を用意しておくこと。
# 引数: 1=ユーザー名 2=git URL 3=クローン先ディレクトリ名 4=表示ラベル（省略時は3）
_makepkg_git_install() {
  local user="$1" giturl="$2" dir="$3" label="${4:-$3}"
  run_cmd_soft "${label} のビルド & インストール（ユーザー: ${user}）" \
    arch-chroot /mnt sudo -u "${user}" -H bash -c '
      set -e
      bd="$HOME/aur-build"; mkdir -p "$bd"; cd "$bd"
      for i in 1 2 3; do
        rm -rf "'"${dir}"'"
        git clone --depth=1 "'"${giturl}"'" "'"${dir}"'" && break
        echo "git clone に失敗、リトライ ($i/3)"; sleep 5
        [ "$i" = 3 ] && exit 1
      done
      cd "'"${dir}"'"
      makepkg -si --noconfirm --needed
      cd "$HOME"; rm -rf "$bd/'"${dir}"'"
    '
}

# AUR パッケージ1つをビルド&インストール（_makepkg_git_install の AUR 版ラッパー）。
# 引数1: ユーザー名, 引数2: AUR リポジトリ名（=パッケージ名）
_aur_makepkg_install() {
  local user="$1" repo="$2"
  _makepkg_git_install "$user" "https://aur.archlinux.org/${repo}.git" "$repo" "$repo"
}

# AUR/Chrome が入らなかった場合の手動導入手順を表示
_aur_manual_hint() {
  local helper="$1"
  print_warn "後から手動で導入する場合（再起動後、一般ユーザーで実行）:"
  echo -e "    ${GRAY}sudo pacman -S --needed git base-devel${RESET}"
  if [[ "${CONFIG[install_chrome]:-no}" == "yes" ]]; then
    echo -e "    ${GRAY}git clone https://aur.archlinux.org/google-chrome.git${RESET}"
    echo -e "    ${GRAY}cd google-chrome && makepkg -si${RESET}"
  fi
  if [[ "$helper" != "none" ]]; then
    local repo="$helper"; [[ "$helper" == "yay" ]] && repo="yay-bin"
    echo -e "    ${GRAY}git clone https://aur.archlinux.org/${repo}.git && cd ${repo} && makepkg -si${RESET}"
  fi
  if [[ "${CONFIG[install_ytfzf]:-no}" == "yes" ]]; then
    echo -e "    ${GRAY}git clone https://github.com/yannsi/yt-fzf-sh && cd yt-fzf-sh && makepkg -si${RESET}"
  fi
}

do_aur_helper() {
  local helper="${CONFIG[aur_helper]}"
  local want_chrome="${CONFIG[install_chrome]:-no}"
  local want_ytfzf="${CONFIG[install_ytfzf]:-no}"

  # AUR ヘルパーも Chrome も yt-fzf も不要ならスキップ
  [[ "$helper" == "none" && "$want_chrome" != "yes" && "$want_ytfzf" != "yes" ]] && return

  # 代表ユーザー名を取得（CONFIG[users] の最初のユーザー）
  local first_user
  first_user=$(cut -d'|' -f1 <<< "$(head -n1 <<< "${CONFIG[users]}")")
  if [[ -z "$first_user" ]]; then
    print_warn "一般ユーザーが登録されていないため、追加パッケージのインストールをスキップします。"
    return
  fi

  print_step "追加パッケージのインストール（AUR ヘルパー / Chrome / yt-fzf）"

  # ドライランのときはスキップ
  if [[ "${CONFIG[dry_run]}" == "yes" ]]; then
    print_warn "ドライランのため AUR 関連をスキップします"
    return
  fi

  # chroot 内の AUR 接続確認（AUR/Chrome 用。yt-fzf は GitHub なので clone 時に個別判定）
  local aur_ok="yes"
  if [[ "$helper" != "none" || "$want_chrome" == "yes" ]]; then
    echo -ne "  ${CYAN}…${RESET} chroot 内の AUR 接続を確認中..."
    if arch-chroot /mnt git ls-remote "https://aur.archlinux.org/google-chrome.git" &>/dev/null; then
      echo -e "\r  ${GREEN}✔${RESET} chroot 内の AUR 接続OK"
    else
      aur_ok="no"
      echo -e "\r  ${YELLOW}⚠${RESET} chroot 内で AUR に接続できません — AUR/Chrome はスキップします"
      print_warn "DNS（/etc/resolv.conf）の同期不良などが原因の可能性があります。"
      _aur_manual_hint "$helper"
    fi
  fi

  # makepkg は root で実行できないため、非対話ビルド用に一時的な NOPASSWD sudo を付与。
  # 重要: sudoers.d は「ファイル名の辞書順」に読まれ、同一ユーザーでは後勝ち。
  # do_users がユーザー名（例 taro＝パスワードあり）でファイルを作るため、
  # 数字始まりの名前（例 99-...）だと taro より前に読まれ、上書きされて無効化される。
  # そこで「ユーザー名＋接尾辞」の名前にし、必ず当該ユーザーのファイルより後に読ませる。
  local temp_sudoers="/etc/sudoers.d/${first_user}-aur-nopasswd"
  run_cmd "一時的な sudo NOPASSWD 設定の追加" bash -c "
    echo '${first_user} ALL=(ALL:ALL) NOPASSWD: ALL' > /mnt${temp_sudoers}
    chmod 0440 /mnt${temp_sudoers}
  "

  # ── 1) AUR ヘルパー（任意）──
  if [[ "$helper" != "none" && "$aur_ok" == "yes" ]]; then
    local repo_name="$helper"
    [[ "$helper" == "yay" ]] && repo_name="yay-bin"
    if _aur_makepkg_install "$first_user" "$repo_name"; then
      print_ok "${helper} をインストールしました（今後の AUR は「${helper} -S <名前>」で導入可）"
    else
      print_warn "${helper} のインストールに失敗しました（スキップして継続）"
    fi
  fi

  # ── 2) Google Chrome（yay に依存せず AUR から直接ビルド）──
  # google-chrome の依存は公式リポジトリのみのため、makepkg -si 単体で完結する。
  if [[ "$want_chrome" == "yes" && "$aur_ok" == "yes" ]]; then
    if _aur_makepkg_install "$first_user" "google-chrome"; then
      print_ok "Google Chrome をインストールしました"
    else
      print_warn "Google Chrome のインストールに失敗しました（後から makepkg で導入できます）"
    fi
  fi

  # ── 3) yt-fzf-sh（GitHub の PKGBUILD から直接ビルド）──
  # fzf/yt-dlp を使う対話的 YouTube ダウンローダ/再生ツール。
  # 依存(fzf, yt-dlp, mpv, ffmpeg)は makepkg -si が公式リポジトリから自動導入する。
  if [[ "$want_ytfzf" == "yes" ]]; then
    if _makepkg_git_install "$first_user" \
         "https://github.com/yannsi/yt-fzf-sh" "yt-fzf-sh" "yt-fzf-sh (YouTube ツール)"; then
      print_ok "yt-fzf-sh をインストールしました（コマンド: ${BOLD}yt-fzf${RESET}）"
      # Wayland クリップボード連携(optdepend)。本インストーラは全DEが Wayland のため導入。
      run_cmd_soft "wl-clipboard 導入（yt-fzf のクリップボード連携）" \
        arch-chroot /mnt pacman -S --noconfirm --needed wl-clipboard || true
    else
      print_warn "yt-fzf-sh のインストールに失敗しました（後から手動で導入できます）"
    fi
  fi

  # 一時的な sudo 設定を削除
  run_cmd "一時的な sudo NOPASSWD 設定の削除" rm -f "/mnt${temp_sudoers}"
}

# ============================================
# ユーティリティ: Waybar 設定ファイルを生成
# 引数1: WM 名（hyprland / niri）
# ============================================

write_waybar_config() {
  local wm="$1"
  local tz="${CONFIG[timezone]:-Asia/Tokyo}"

  # dry_run 時は /mnt がマウントされていないためスキップ
  if [[ "${CONFIG[dry_run]}" == "yes" ]]; then
    print_warn "ドライランのため Waybar 設定生成をスキップします (${wm})"
    return 0
  fi

  local dest_dir="/mnt/etc/skel/.config/waybar"
  mkdir -p "$dest_dir"

  # ホストPCの ~/.config/waybar/ が存在する場合、その設定とカスタムスクリプトをコピーする
  local host_home
  host_home=$(_host_home)
  local host_waybar_dir=""
  [[ -n "$host_home" ]] && host_waybar_dir="${host_home}/.config/waybar"

  if [[ -d "$host_waybar_dir" ]]; then
    run_cmd "ホストPCからWaybar設定をコピー" cp -a "$host_waybar_dir/." "$dest_dir/"
    
    # 1. config.jsonc: ハードコードされたユーザー絶対パスを $HOME に置換
    if [[ -f "$dest_dir/config.jsonc" ]]; then
      local user_pat; user_pat=$(basename "$host_home")
      sed -i "s|/home/${user_pat}/.config/waybar/|\$HOME/.config/waybar/|g" "$dest_dir/config.jsonc"

      # WMに応じたワークスペース・ウィンドウモジュールの動的書き換え
      if [[ "$wm" == "hyprland" ]]; then
        sed -i 's/niri\/workspaces/hyprland\/workspaces/g' "$dest_dir/config.jsonc"
        sed -i 's/niri\/window/hyprland\/window/g' "$dest_dir/config.jsonc"
        # hyprland/workspaces のオプションを追加
        sed -i 's/"hyprland\/workspaces": {/"hyprland\/workspaces": {\n        "disable-scroll": true,\n        "all-outputs": true,/g' "$dest_dir/config.jsonc"
      fi
    fi

    # 2. style.css: ハードコードされたアイコン絶対パスを相対パスに置換
    if [[ -f "$dest_dir/style.css" ]]; then
      local user_pat; user_pat=$(basename "$host_home")
      sed -i "s|/home/${user_pat}/.config/waybar/||g" "$dest_dir/style.css"
      
      # アクティブなクラス名をWMごとに調整
      local active_class="focused"
      [[ "$wm" == "hyprland" || "$wm" == "niri" ]] && active_class="active"
      if [[ "$active_class" != "focused" ]]; then
        sed -i "s/button.focused/button.${active_class}/g" "$dest_dir/style.css"
      fi
    fi

    # 3. radio.sh: ハードコードされた mpv-title.lua のパスを置換
    if [[ -f "$dest_dir/radio.sh" ]]; then
      local user_pat; user_pat=$(basename "$host_home")
      sed -i "s|/home/${user_pat}/.config/waybar/|\$HOME/.config/waybar/|g" "$dest_dir/radio.sh"
    fi

    # 4. power_menu.sh: Hyprland 用 of logout/lock support
    if [[ -f "$dest_dir/power_menu.sh" ]]; then
      if [[ "$wm" == "hyprland" ]]; then
        sed -i 's/niri msg action quit --skip-confirmation/hyprctl dispatch exit/g' "$dest_dir/power_menu.sh"
      fi
    fi

    print_ok "Waybar: ホストPCのカスタム設定（${wm} 向け調整済み）を適用しました"
    return 0
  fi

  # WM に応じたワークスペースモジュール名を決定
  local ws_module
  case "$wm" in
    hyprland)  ws_module="hyprland/workspaces" ;;
    niri)      ws_module="niri/workspaces" ;;
    *)         ws_module="${wm}/workspaces" ;;
  esac

  # WM 固有の追加モジュール（hyprland は submap を追加）
  # 各エントリは "モジュール名" のみ（カンマ・インデントは後で付与）
  local extra_left_modules=()
  if [[ "$wm" == "hyprland" ]]; then
    extra_left_modules=("hyprland/submap")
  fi

  # WM 固有のワークスペース設定（disable-scroll, all-outputs は hyprland のみ）
  local ws_options=""
  if [[ "$wm" != "niri" ]]; then
    ws_options='"disable-scroll": true,
        "all-outputs": true,'
  fi

  # ワークスペースボタンのアクティブ CSS クラス名（WM ごとに異なる）
  local active_class
  case "$wm" in
    hyprland|niri) active_class="active" ;;
    *)             active_class="focused" ;;
  esac

  mkdir -p /mnt/etc/skel/.config/waybar

  # modules-left を構築（trailing comma なしの正しい JSON）
  local modules_left_json="        \"${ws_module}\""
  if [[ ${#extra_left_modules[@]} -gt 0 ]]; then
    modules_left_json=""
    for mod in "${extra_left_modules[@]}"; do
      modules_left_json+="        \"${mod}\","$'\n'
    done
    modules_left_json+="        \"${ws_module}\""
  fi

  cat > /mnt/etc/skel/.config/waybar/config.jsonc << EOF
{
    "layer": "top",
    "position": "top",
    "height": 30,
    "spacing": 4,
    "modules-left": [
        ${modules_left_json}
    ],
    "modules-center": [
        "clock"
    ],
    "modules-right": [
        "pulseaudio",
        "battery",
        "tray"
    ],
    "${ws_module}": {
        ${ws_options}
        "format": "{name}"
    },
    "clock": {
        "timezone": "${tz}",
        "tooltip-format": "<big>{:%Y %B}</big>\n<tt><small>{calendar}</small></tt>",
        "format": "{:%Y-%m-%d %H:%M:%S}",
        "interval": 1
    },
    "pulseaudio": {
        "format": " {volume}%",
        "format-muted": " Muted",
        "on-click": "pavucontrol"
    },
    "battery": {
        "states": {
            "warning": 30,
            "critical": 15
        },
        "format": "{icon} {capacity}%",
        "format-charging": " {capacity}%",
        "format-plugged": " {capacity}%",
        "format-icons": ["", "", "", "", ""]
    },
    "tray": {
        "spacing": 10
    }
}
EOF

  cat > /mnt/etc/skel/.config/waybar/style.css << EOF
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
#workspaces button.${active_class} {
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
EOF
}

# ============================================
# 実行: デスクトップ環境
# ============================================

do_desktop() {
  [[ "${CONFIG[desktop]}" == "none" ]] && return

  # dry_run 時は /mnt がマウントされていないためスキップ
  if [[ "${CONFIG[dry_run]}" == "yes" ]]; then
    print_warn "ドライランのためデスクトップ環境のセットアップをスキップします"
    return 0
  fi

  # pipewire-jack と jack2 の競合を事前に回避
  if arch-chroot /mnt pacman -Qi jack2 &>/dev/null; then
    run_cmd "jack2 の一時削除 (pipewire-jack 競合回避)" \
      arch-chroot /mnt pacman -Rdd --noconfirm jack2
  fi

  print_step "デスクトップ環境のインストール: ${CONFIG[desktop]}"

  # 音声・Bluetooth・ファイルシステム・マルチメディア・ブラウザなどのデスクトップ共通パッケージ
  local desktop_common_pkgs=(
    pipewire pipewire-pulse wireplumber
    pipewire-alsa pipewire-jack libldac
    bluez bluez-utils
    cups cups-pdf avahi nss-mdns system-config-printer
    xdg-user-dirs xdg-utils
    firefox
    ntfs-3g exfatprogs
    gvfs gvfs-mtp gvfs-smb
    gnome-disk-utility
    gst-plugins-good gst-libav
    libdvdcss libdvdread libdvdnav
  )

  case "${CONFIG[desktop]}" in
    kde)
      local pkgs=(sddm-kcm konsole dolphin colord-kde)
      if [[ "${CONFIG[kde_apps]}" == "minimal" ]]; then
        pkgs+=(plasma-desktop)
      elif [[ "${CONFIG[kde_apps]}" == "standard" ]]; then
        pkgs+=(plasma-meta)
      elif [[ "${CONFIG[kde_apps]}" == "full" ]]; then
        pkgs+=(plasma-meta kde-applications)
      else
        pkgs+=(plasma-desktop)
      fi
      run_cmd_retry "KDE Plasma インストール" \
        arch-chroot /mnt pacman -S --noconfirm "${pkgs[@]}" "${desktop_common_pkgs[@]}"
      ;;

    gnome)
      local pkgs=(gnome gnome-tweaks power-profiles-daemon)
      run_cmd_retry "GNOME インストール" \
        arch-chroot /mnt pacman -S --noconfirm "${pkgs[@]}" "${desktop_common_pkgs[@]}"
      
      # 電源プロファイルデーモンの有効化
      run_cmd "power-profiles-daemon 有効化" systemctl --root=/mnt enable power-profiles-daemon

      # gnome-initial-setupをパッケージレベルで削除して初期ウィザードを確実にスキップ
      run_cmd_soft "GNOME 初期セットアップウィザード無効化 (パッケージ削除)" \
        arch-chroot /mnt pacman -Rns --noconfirm gnome-initial-setup || true

      # gnome-keyringの有効化（Polkit等と親和性）
      run_cmd_retry "GNOME パッケージインストール (gnome-keyring)" arch-chroot /mnt pacman -S --noconfirm gnome-keyring
      ;;

    xfce)
      local pkgs=(xfce4 xfce4-goodies network-manager-applet)
      run_cmd_retry "Xfce インストール" \
        arch-chroot /mnt pacman -S --noconfirm "${pkgs[@]}" "${desktop_common_pkgs[@]}"
      ;;

    budgie)
      local pkgs=(budgie budgie-control-center nautilus gnome-console network-manager-applet gedit evince file-roller eog gnome-screenshot power-profiles-daemon brightnessctl)
      run_cmd_retry "Budgie インストール" \
        arch-chroot /mnt pacman -S --noconfirm "${pkgs[@]}" "${desktop_common_pkgs[@]}"
      
      # 電源プロファイルデーモンの有効化（Budgie/GNOMEの電源管理に必須級）
      run_cmd "power-profiles-daemon 有効化" systemctl --root=/mnt enable power-profiles-daemon

      # 照度スライダーがキーボードを押すまで表示されないバグの回避策
      # ログイン時に brightnessctl でダミーのイベントを発生させる
      run_cmd "Budgie 照度スライダー回避スクリプト追加" bash -c "
        mkdir -p /mnt/etc/skel/.config/autostart
        cat > /mnt/etc/skel/.config/autostart/brightness-fix.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=Brightness Slider Fix
Exec=sh -c 'sleep 2 && brightnessctl s +0%'
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF
      "

      print_ok "Budgie 10.10+ (Wayland 対応)"
      print_warn "mutter/gnome-settings-daemon が Budgie の依存関係としてインストールされているか確認してください。"
      ;;

    cosmic)
      # Cosmic desktop (AUR or extra-testing)
      local pkgs=(cosmic)
      run_cmd_retry "COSMIC インストール" \
        arch-chroot /mnt pacman -S --noconfirm "${pkgs[@]}" "${desktop_common_pkgs[@]}"
      ;;



    hyprland)
      local pkgs=(hyprland uwsm hyprpaper hyprlock hypridle
                  waybar wofi kitty
                  alacritty fuzzel cava streamlink
                  xorg-xwayland
                  xdg-desktop-portal-hyprland xdg-desktop-portal-gtk
                  pavucontrol polkit-gnome
                  blueman
                  network-manager-applet
                  grim slurp wl-clipboard
                  mako
                  brightnessctl
                  nautilus
                  mousepad imv zathura zathura-pdf-mupdf mpv xarchiver
                  ttf-jetbrains-mono-nerd)
      run_cmd_retry "Hyprland インストール" \
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

      # ── ビジュアル設定（角丸・カラー・アニメーション） ──
      cat >> /mnt/etc/skel/.config/hypr/hyprland.conf << 'EOF'

# ── general ──
general {
    gaps_in = 5
    gaps_out = 10
    border_size = 2
    col.active_border = rgba(1ca2f1ee) rgba(3bc7ffee) 45deg
    col.inactive_border = rgba(0d1c2eaa)
    layout = dwindle
    resize_on_border = true
}

# ── decoration ──
decoration {
    rounding = 12
    active_opacity = 1.0
    inactive_opacity = 0.93

    shadow {
        enabled = true
        range = 14
        render_power = 3
        color = rgba(00000088)
        color_inactive = rgba(00000044)
    }

    blur {
        enabled = true
        size = 8
        passes = 3
        new_optimizations = true
        xray = false
    }
}

# ── animations ──
animations {
    enabled = true
    bezier = easeOut,  0.16, 1,    0.3, 1
    bezier = easeIn,   0.7,  0,    0.84, 0
    bezier = spring,   0.05, 0.9,  0.1, 1.05
    animation = windows,    1, 6, spring
    animation = windowsOut, 1, 5, easeIn, popin 80%
    animation = border,     1, 8, default
    animation = borderangle,1, 6, default
    animation = fade,       1, 5, easeOut
    animation = workspaces, 1, 5, easeOut, slidevert
}

# ── dwindle layout ──
dwindle {
    preserve_split = true
}

# ── misc ──
misc {
    force_default_wallpaper = 0
    disable_hyprland_logo = true
    animate_manual_resizes = true
    mouse_move_enables_dpms = true
    key_press_enables_dpms = true
}
EOF

      # 初心者向けキーバインド（wofi, Nautilus, Firefox）の追加
      cat >> /mnt/etc/skel/.config/hypr/hyprland.conf << 'EOF'

# アプリ起動用の初心者向けキーバインド
bind = $mainMod, D, exec, wofi --show drun
bind = $mainMod SHIFT, F, exec, nautilus
bind = $mainMod SHIFT, W, exec, firefox
EOF

      # 自動起動設定（nm-applet の追加）
      echo 'exec-once = nm-applet --indicator' >> /mnt/etc/skel/.config/hypr/hyprland.conf
      if [[ "${CONFIG[jp_ime]:-none}" =~ ^fcitx5 ]]; then
        echo 'exec-once = fcitx5 -d' >> /mnt/etc/skel/.config/hypr/hyprland.conf
      elif [[ "${CONFIG[jp_ime]:-none}" =~ ^ibus ]]; then
        echo 'exec-once = ibus-daemon -drx' >> /mnt/etc/skel/.config/hypr/hyprland.conf
      fi

      # キーボードレイアウト設定
      if [[ "${CONFIG[keymap]}" == "jp106" ]]; then
        printf 'input {\n    kb_layout = jp\n    kb_model = jp106\n}\n' >> /mnt/etc/skel/.config/hypr/hyprland.conf
      elif [[ -n "${CONFIG[keymap]}" && "${CONFIG[keymap]}" != "none" ]]; then
        local wl_layout="${CONFIG[keymap]}"
        [[ "$wl_layout" == "uk" ]] && wl_layout="gb"
        printf 'input {\n    kb_layout = %s\n}\n' "${wl_layout}" >> /mnt/etc/skel/.config/hypr/hyprland.conf
      fi

      # ── 日本語ロケールを Hyprland の環境に設定 ──
      # これが無いと fontconfig がフォールバックで中国語字形(SC)を選び、
      # ターミナル等の漢字が「変な字形」になる。
      if [[ "${CONFIG[japanese_env]}" == "yes" ]]; then
        local jp_locale="${CONFIG[locale]:-ja_JP.UTF-8}"
        {
          echo "env = LANG,${jp_locale}"
          echo "env = LC_CTYPE,${jp_locale}"
        } >> /mnt/etc/skel/.config/hypr/hyprland.conf
      fi

      # polkit-gnome 認証エージェントの自動起動設定
      echo 'exec-once = /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1' >> /mnt/etc/skel/.config/hypr/hyprland.conf

      # Waybar 設定の配置
      write_waybar_config "hyprland"

      # waybar の自動起動設定
      # 既定設定が waybar を起動する版もあるため、有効な exec-once...waybar が
      # 無い場合のみ追加する（二重起動の防止。コメント行 "# exec-once" は不一致）。
      if ! grep -qE '^[[:space:]]*exec-once[[:space:]]*=.*waybar' /mnt/etc/skel/.config/hypr/hyprland.conf; then
        echo 'exec-once = waybar' >> /mnt/etc/skel/.config/hypr/hyprland.conf
      fi

      # 音量・輝度キーバインド:
      # Hyprland の既定 example 設定には既に含まれているため、
      # フォールバック設定を使った場合（copied=0）のみ追加して重複を避ける。
      if [ $copied -eq 0 ]; then
        cat >> /mnt/etc/skel/.config/hypr/hyprland.conf << 'EOF'

# 音量・輝度キーのバインド（wpctl / brightnessctl 利用）
bindel = , XF86AudioRaiseVolume, exec, wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+
bindel = , XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
bindl = , XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
bindl = , XF86AudioMicMute, exec, wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle
bindel = , XF86MonBrightnessUp, exec, brightnessctl set 10%+
bindel = , XF86MonBrightnessDown, exec, brightnessctl set 10%-
EOF
      fi

      # Waybar の表示トグル（既定設定には無いので常に追加）
      cat >> /mnt/etc/skel/.config/hypr/hyprland.conf << 'EOF'

# Waybar の表示トグル（非表示 / 再起動）
bind = SUPER, B, exec, pkill waybar || waybar
EOF
      ;;

    niri)
      local pkgs=(niri xwayland-satellite
                  waybar swaybg swaylock swayidle mako
                  alacritty fuzzel cava streamlink
                  xdg-desktop-portal-gnome xdg-desktop-portal-gtk
                  pavucontrol polkit-gnome
                  blueman
                  network-manager-applet
                  grim slurp wl-clipboard
                  brightnessctl
                  nautilus
                  mousepad imv zathura zathura-pdf-mupdf mpv xarchiver
                  ttf-jetbrains-mono-nerd)
      run_cmd_retry "Niri インストール" \
        arch-chroot /mnt pacman -S --noconfirm "${pkgs[@]}" "${desktop_common_pkgs[@]}"

      # デフォルト設定ファイルのコピー
      mkdir -p /mnt/etc/skel/.config/niri
      if [ -f /mnt/usr/share/doc/niri/default-config.kdl ]; then
        cp /mnt/usr/share/doc/niri/default-config.kdl /mnt/etc/skel/.config/niri/config.kdl
      elif [ -f /mnt/usr/share/doc/niri/config.kdl ]; then
        cp /mnt/usr/share/doc/niri/config.kdl /mnt/etc/skel/.config/niri/config.kdl
      fi

      # ── Niri ビジュアル設定の適用 ──
      if [[ -f /mnt/etc/skel/.config/niri/config.kdl ]]; then
        # 1. 角丸ウィンドウルールの有効化（/-window-rule → window-rule）
        sed -i 's|^/-window-rule {|window-rule {|g' \
          /mnt/etc/skel/.config/niri/config.kdl

        # 2. フォーカスリング: アクティブグラデーション（テーマカラーに合わせる）
        sed -i 's|//\s*active-color "#7fc8ff"|active-gradient from="#1ca2f1" to="#3bc7ff" angle=45|' \
          /mnt/etc/skel/.config/niri/config.kdl

        # 3. シャドウを有効化（コメントアウトされた '// on' を有効化）
        sed -i 's|^\( *\)// on$|\1on|' \
          /mnt/etc/skel/.config/niri/config.kdl

        print_ok "Niri: 角丸・フォーカスリング・シャドウを設定しました"
      else
        # デフォルト設定がない場合: 最小ビジュアル設定を追記
        cat >> /mnt/etc/skel/.config/niri/config.kdl << 'EOF'

layout {
    gaps 10
    focus-ring {
        width 4
        active-gradient from="#1ca2f1" to="#3bc7ff" angle=45
        inactive-color "#0d182c"
    }
    border {
        off
    }
    shadow {
        on
    }
}

window-rule {
    geometry-corner-radius 12
    clip-to-geometry true
}
EOF
        print_ok "Niri: 最小ビジュアル設定を追加しました"
      fi

      # ── 追加キーバインド（重複ブロック・重複キーを避け、既存 binds{} 内へ挿入）──
      # niri 既定に Mod+D(fuzzel) / Mod+T(端末) / Mod+Shift+F(全画面) 等があるため、
      # それらと衝突しない Mod+E / Mod+Shift+B / Mod+B を使い、既存 binds ブロックへ差し込む。
      # （別々の binds{} ブロックを増やすと niri がパースエラーで設定を無効化するため）
      local niri_cfg=/mnt/etc/skel/.config/niri/config.kdl
      if [ -f "$niri_cfg" ]; then
        printf '    Mod+E { spawn "nautilus"; }\n    Mod+Shift+B { spawn "firefox"; }\n    Mod+B { spawn "sh" "-c" "pkill waybar || waybar"; }\n' > /tmp/niri_binds.txt
        if grep -q '^binds {' "$niri_cfg"; then
          sed -i '/^binds {/r /tmp/niri_binds.txt' "$niri_cfg"
        else
          { echo 'binds {'; cat /tmp/niri_binds.txt; echo '}'; } >> "$niri_cfg"
        fi
        rm -f /tmp/niri_binds.txt
        print_ok "Niri: 追加バインド Mod+E=ファイル / Mod+Shift+B=ブラウザ / Mod+B=Waybar切替"
      fi

      # Waybar 設定の配置
      write_waybar_config "niri"

      # 自動起動設定（nm-applet などの追加）
      # waybar は niri のデフォルト設定が既に spawn-at-startup で起動するため、
      # 有効な spawn-at-startup "waybar" が無い場合のみ追加する（二重起動の防止）。
      # （コメント行 "// spawn-at-startup ..." は ^\s*spawn では一致しないので追加される）
      if ! grep -qE '^[[:space:]]*spawn-at-startup[[:space:]]+"waybar"' /mnt/etc/skel/.config/niri/config.kdl; then
        echo 'spawn-at-startup "waybar"' >> /mnt/etc/skel/.config/niri/config.kdl
      fi
      echo 'spawn-at-startup "nm-applet" "--indicator"' >> /mnt/etc/skel/.config/niri/config.kdl
      if [[ "${CONFIG[jp_ime]:-none}" =~ ^fcitx5 ]]; then
        echo 'spawn-at-startup "fcitx5" "-d"' >> /mnt/etc/skel/.config/niri/config.kdl
      elif [[ "${CONFIG[jp_ime]:-none}" =~ ^ibus ]]; then
        echo 'spawn-at-startup "ibus-daemon" "-drx"' >> /mnt/etc/skel/.config/niri/config.kdl
      fi

      # ── キーボードレイアウト（既存 input/xkb 内へ挿入。input ブロックを重複させない）──
      local xkb_insert=""
      if [[ "${CONFIG[keymap]}" == "jp106" ]]; then
        xkb_insert=$(printf '            layout "jp"\n            model "jp106"\n')
      elif [[ -n "${CONFIG[keymap]}" && "${CONFIG[keymap]}" != "none" ]]; then
        local wl_layout="${CONFIG[keymap]}"
        [[ "$wl_layout" == "uk" ]] && wl_layout="gb"
        xkb_insert=$(printf '            layout "%s"\n' "$wl_layout")
      fi
      if [[ -n "$xkb_insert" && -f "$niri_cfg" ]]; then
        printf '%s\n' "$xkb_insert" > /tmp/niri_xkb.txt
        if grep -q 'xkb {' "$niri_cfg"; then
          sed -i '/xkb {/r /tmp/niri_xkb.txt' "$niri_cfg"
        else
          { echo 'input {'; echo '    keyboard {'; echo '        xkb {'
            cat /tmp/niri_xkb.txt
            echo '        }'; echo '    }'; echo '}'; } >> "$niri_cfg"
        fi
        rm -f /tmp/niri_xkb.txt
      fi

      # ── 日本語ロケールを niri の環境に設定 ──
      # niri が spawn する全アプリ（ターミナル等）に LANG を渡す。これが無いと
      # fontconfig がフォールバック時に中国語字形(SC)を選び、漢字が「変な字形」になる。
      if [[ "${CONFIG[japanese_env]}" == "yes" && -f "$niri_cfg" ]]; then
        if ! grep -qE '^[[:space:]]*environment[[:space:]]*\{' "$niri_cfg"; then
          local jp_locale="${CONFIG[locale]:-ja_JP.UTF-8}"
          cat >> "$niri_cfg" << EOF

environment {
    LANG "${jp_locale}"
    LC_CTYPE "${jp_locale}"
}
EOF
          print_ok "Niri: LANG=${jp_locale} を設定（漢字を日本語字形で表示）"
        fi
      fi

      # polkit-gnome 認証エージェントの自動起動設定
      echo 'spawn-at-startup "/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1"' >> /mnt/etc/skel/.config/niri/config.kdl
      
      # swayidle の自動起動設定（30分でロック、60分でサスペンド）
      echo 'spawn-at-startup "swayidle" "-w" "timeout" "1800" "swaylock -f" "timeout" "3600" "systemctl suspend" "before-sleep" "swaylock -f"' >> /mnt/etc/skel/.config/niri/config.kdl

      print_ok "スクロール型タイリング: 横スクロールで無限ワークスペース"
      ;;
  esac

  # Hyprland, Niri 用の MIME デフォルト関連付け設定 (mimeapps.list)
  case "${CONFIG[desktop]}" in
    hyprland|niri)
      run_cmd "MIME デフォルト関連付け設定 (Hyprland/Niri)" bash -c "
        mkdir -p /mnt/etc/skel/.config
        cat > /mnt/etc/skel/.config/mimeapps.list << 'EOF'
[Default Applications]
text/html=firefox.desktop
x-scheme-handler/http=firefox.desktop
x-scheme-handler/https=firefox.desktop
x-scheme-handler/about=firefox.desktop
x-scheme-handler/unknown=firefox.desktop
inode/directory=org.gnome.Nautilus.desktop
text/plain=org.xfce.mousepad.desktop
application/pdf=org.pwmt.zathura.desktop
image/png=imv.desktop
image/jpeg=imv.desktop
image/gif=imv.desktop
image/webp=imv.desktop
video/mp4=mpv.desktop
video/x-matroska=mpv.desktop
video/webm=mpv.desktop
audio/mpeg=mpv.desktop
audio/flac=mpv.desktop
audio/ogg=mpv.desktop
EOF
      "
      ;;
  esac

  # ── alacritty のフォント明示（niri/Hyprland）──
  # alacritty は既定で "monospace" を使うが、日本語のフォールバックを確実にするため
  # 主フォントを明示する。CJK フォールバック(JP)は上の fontconfig の match で保証される。
  case "${CONFIG[desktop]}" in
    hyprland|niri)
      run_cmd "alacritty フォント設定" bash -c "
        mkdir -p /mnt/etc/skel/.config/alacritty
        cat > /mnt/etc/skel/.config/alacritty/alacritty.toml << 'EOF'
[font]
size = 11.0

[font.normal]
family = \"JetBrainsMono Nerd Font\"
style = \"Regular\"
EOF
      "
      ;;
  esac
  # GUI デスクトップを選んだ場合、最低限の実用アプリを導入して
  # 「入れたけど何もできない」状態を防ぐ。--needed で既存パッケージの重複導入を回避。
  local recommended_pkgs=(
    libreoffice-fresh          # オフィス（文書・表計算・プレゼン）※ロケール ja_JP で日本語UI
    unzip p7zip                # zip / 7z の解凍
    wget curl git              # ダウンロード・取得
    nano htop                  # やさしいエディタ・システムモニタ
  )
  if [[ "${CONFIG[japanese_env]}" == "yes" ]]; then
    recommended_pkgs+=(firefox-i18n-ja)   # Firefox の日本語UI言語パック
  fi
  run_cmd_retry "初心者向け推奨アプリのインストール" \
    arch-chroot /mnt pacman -S --noconfirm --needed "${recommended_pkgs[@]}"
  print_ok "推奨アプリ導入完了（LibreOffice ほか）"

  # デスクトップ用共通サービス（Bluetooth, CUPS, Avahi）有効化
  if [[ "${CONFIG[desktop]}" != "none" ]]; then
    run_cmd "Bluetooth サービス有効化" systemctl --root=/mnt enable bluetooth
    run_cmd "CUPS (印刷) サービス有効化" systemctl --root=/mnt enable cups
    run_cmd "Avahi (ネットワーク探索) サービス有効化" systemctl --root=/mnt enable avahi-daemon
    run_cmd "ローカルホスト名解決 (nss-mdns) の設定" sed -i '/^hosts:/ s/ \(resolve\|dns\)/ mdns_minimal [NOTFOUND=return] \1/' /mnt/etc/nsswitch.conf
  fi

  # ホストPCの各種アプリ設定（fuzzel, alacritty, mako, cava, mpv）をターゲットの /etc/skel にコピー
  if [[ "${CONFIG[dry_run]}" != "yes" ]]; then
    local host_home host_config_dir=""
    host_home=$(_host_home)
    [[ -n "$host_home" ]] && host_config_dir="${host_home}/.config"

    if [[ -d "$host_config_dir" ]]; then
      mkdir -p /mnt/etc/skel/.config
      local app_configs=(fuzzel alacritty mako cava mpv)
      for app in "${app_configs[@]}"; do
        if [[ -d "$host_config_dir/$app" ]]; then
          run_cmd "ホストPCから ${app} 設定をコピー" cp -a "$host_config_dir/$app" /mnt/etc/skel/.config/
        fi
      done
    fi
  fi

  # 各一般ユーザーのホームディレクトリに /etc/skel の内容（デスクトップ設定含む）をコピーして所有権を設定
  if [[ "${CONFIG[dry_run]}" != "yes" ]]; then
    local entry uname upw usudo ushell ugroups
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      parse_users_line "$entry"
      if [[ -d "/mnt/home/$uname" ]]; then
        run_cmd "ユーザー設定ファイルの同期: ${uname}" bash -c "
          cp -a /mnt/etc/skel/. /mnt/home/${uname}/
          chown -R ${uname}: /mnt/home/${uname}
        "
        if arch-chroot /mnt command -v xdg-user-dirs-update &>/dev/null; then
          run_cmd "ユーザーディレクトリ初期作成: ${uname}" \
            arch-chroot /mnt bash -c "
              HOME=/home/${uname} \
              LANG=${CONFIG[locale]} \
              XDG_CONFIG_HOME=/home/${uname}/.config \
              xdg-user-dirs-update --force
              chown -R ${uname}: /home/${uname}
            "
        fi
      fi
    done <<< "${CONFIG[users]}"
  fi
}
do_display_manager() {
  local dm="${CONFIG[dm]}"
  [[ "$dm" == "none" ]] && { print_ok "DM なし: TTY から手動起動"; return; }

  print_step "ディスプレイマネージャーのセットアップ: ${dm}"

  case "$dm" in
    sddm)
      run_cmd_retry "SDDM インストール" \
        arch-chroot /mnt pacman -S --noconfirm sddm
      run_cmd "SDDM 有効化" systemctl --root=/mnt enable sddm
      ;;

    gdm)
      run_cmd_retry "GDM インストール" \
        arch-chroot /mnt pacman -S --noconfirm gdm
      run_cmd "GDM 有効化" systemctl --root=/mnt enable gdm
      ;;

    lightdm)
      run_cmd_retry "LightDM インストール" \
        arch-chroot /mnt pacman -S --noconfirm \
          lightdm lightdm-gtk-greeter
      run_cmd "LightDM 有効化" systemctl --root=/mnt enable lightdm
      ;;

    cosmic-greeter)
      run_cmd_retry "cosmic-greeter インストール" \
        arch-chroot /mnt pacman -S --noconfirm cosmic-greeter
      run_cmd "cosmic-greeter 有効化" \
        systemctl --root=/mnt enable cosmic-greeter
      ;;

    greetd)
      run_cmd_retry "greetd インストール" \
        arch-chroot /mnt pacman -S --noconfirm greetd greetd-tuigreet

      # セッションコマンドを DE に応じて決める
      local session_cmd
      case "${CONFIG[desktop]}" in
        hyprland) session_cmd="start-hyprland" ;;
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
      run_cmd "greetd 有効化" systemctl --root=/mnt enable greetd
      print_ok "greetd: セッションコマンド = ${session_cmd}"
      ;;
  esac
}
do_cleanup() {
  print_step "後処理"

  # systemd-resolved の resolv.conf シンボリックリンク設定を最終段階でホスト側から実施
  if [[ "${CONFIG[use_resolved]}" == "yes" ]]; then
    run_cmd "resolv.conf シンボリックリンク設定" \
      ln -sf /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf
  fi

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
  clear
  echo ""
  echo -e "  ${CYAN}${BOLD}myarchinstall${RESET}  ${GRAY}│${RESET}  ${BOLD}インストール実行中${RESET}"
  echo -e "  ${CYAN}$(printf '━%.0s' {1..48})${RESET}"
  echo ""

  # --- 進捗カウンター用の総ステップ数を算出（print_step が [n/N] を表示）---
  # 常に実行される9フェーズ + 条件付き3フェーズ
  STEP_NUM=0
  STEP_TOTAL=9
  { [[ "${CONFIG[aur_helper]}" != "none" ]] || [[ "${CONFIG[install_chrome]:-no}" == "yes" ]] \
      || [[ "${CONFIG[install_ytfzf]:-no}" == "yes" ]]; } \
    && STEP_TOTAL=$(( STEP_TOTAL + 1 ))
  [[ "${CONFIG[desktop]}"    != "none" ]] && STEP_TOTAL=$(( STEP_TOTAL + 1 ))
  [[ "${CONFIG[dm]}"         != "none" ]] && STEP_TOTAL=$(( STEP_TOTAL + 1 ))

  # ファイルシステム固有ツールの確認（選択確定後にインストール）
  case "${CONFIG[fs_type]:-ext4}" in
    btrfs)
      if ! command -v mkfs.btrfs &>/dev/null; then
        print_warn "btrfs-progs をインストールします..."
        pacman -S --noconfirm btrfs-progs || { print_err "btrfs-progs のインストールに失敗しました。"; exit 1; }
      fi ;;
    xfs)
      if ! command -v mkfs.xfs &>/dev/null; then
        print_warn "xfsprogs をインストールします..."
        pacman -S --noconfirm xfsprogs || { print_err "xfsprogs のインストールに失敗しました。"; exit 1; }
      fi ;;
  esac

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

  STEP_TOTAL=0

  echo ""
  echo -e "  ${GREEN}${BOLD}✔ インストール完了！${RESET}  ${GRAY}再起動して日本語環境をお楽しみください${RESET}"
  echo -e "  ${GREEN}$(printf '━%.0s' {1..48})${RESET}"
  echo ""
  echo -e "  再起動コマンド: ${BOLD}reboot${RESET}"

  # 日本語入力のヒント（IME を導入した場合）
  if [[ "${CONFIG[jp_ime]:-none}" != "none" ]]; then
    echo ""
    echo -e "${CYAN}${BOLD}  ── 日本語入力について ──${RESET}"
    echo -e "  日本語入力のオン/オフは ${BOLD}Ctrl + Space${RESET} で切り替えます。"
    echo -e "  デスクトップに初回ログイン後、切り替わらない場合は"
    echo -e "  一度ログアウトして再ログインしてください。"
  fi

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

  # 必要コマンドの確認・自動インストール
  local missing_pkgs=()
  local deps=(
    "sgdisk:gptfdisk"
    "mkfs.fat:dosfstools"
    "mkfs.ext4:e2fsprogs"
    "mkswap:util-linux"
    "swapon:util-linux"
    "mount:util-linux"
    "umount:util-linux"
    "blkid:util-linux"
    "lsblk:util-linux"
    "findmnt:util-linux"
    "reflector:reflector"
    "arch-chroot:arch-install-scripts"
    "genfstab:arch-install-scripts"
    "pacstrap:arch-install-scripts"
    "partprobe:parted"
  )
  for dep in "${deps[@]}"; do
    local cmd="${dep%%:*}"
    local pkg="${dep##*:}"
    if ! command -v "$cmd" &>/dev/null; then
      # 同じパッケージが重複して入らないよう確認
      local already=0
      for p in "${missing_pkgs[@]:-}"; do [[ "$p" == "$pkg" ]] && already=1; done
      [[ "$already" -eq 0 ]] && missing_pkgs+=("$pkg")
    fi
  done

  if [[ "${#missing_pkgs[@]}" -gt 0 ]]; then
    echo -e "${YELLOW}⚠ 以下のパッケージが不足しています: ${missing_pkgs[*]}${RESET}"
    echo -e "  自動インストールします..."
    pacman -Sy --noconfirm "${missing_pkgs[@]}" || {
      echo -e "${RED}✘ 必要パッケージのインストールに失敗しました。${RESET}"
      echo "  手動で実行してください: pacman -S ${missing_pkgs[*]}"
      exit 1
    }
    echo -e "${GREEN}✔ 必要パッケージをインストールしました。${RESET}"
  fi

  # ブートモードを早期検出（step_partition_scheme で参照するため）
  CONFIG[boot_mode]=$(detect_boot_mode)

  # CPU ベンダー検出（マイクロコード選択・ブートローダー設定で共用）
  CONFIG[cpu_vendor]=$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $3}')

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
  if [[ "${CONFIG[dry_run]}" != "yes" ]]; then
    tune_pacman_conf /etc/pacman.conf
  fi

  print_header
  echo -e "  Arch Linux の自動インストールを開始します。"
  echo -e "  各ステップで設定を入力してください。\n"

  if ! confirm "開始しますか？"; then
    echo "中断しました。"
    exit 0
  fi

  step_check_network

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

  # 設定の修正ループ
  while true; do
    echo ""
    local action
    action=$(select_from_list "次のアクションを選択してください:" \
      "このままインストールを実行する" \
      "ディスクを変更する" \
      "パーティション構成・ファイルシステムを変更する" \
      "システム設定を変更する（言語・タイムゾーン・ホスト名など）" \
      "ユーザー設定を変更する" \
      "ブートローダーを変更する" \
      "デスクトップ環境を変更する" \
      "ネットワーク設定を変更する" \
      "ミラーサーバーを変更する" \
      "フォントを変更する" \
      "追加パッケージを変更する" \
      "キャンセルして終了する")

    case "$action" in
      "このままインストールを実行する") break ;;
      "ディスクを変更する")                                   step_disk ;;
      "パーティション構成・ファイルシステムを変更する")       step_partition_scheme ;;
      "システム設定を変更する（言語・タイムゾーン・ホスト名など）") step_system ;;
      "ユーザー設定を変更する")                     step_users ;;
      "ブートローダーを変更する")                   step_bootloader ;;
      "デスクトップ環境を変更する")                 step_desktop ;;
      "ネットワーク設定を変更する")                 step_network ;;
      "ミラーサーバーを変更する")                   step_mirror ;;
      "フォントを変更する")                         step_fonts ;;
      "追加パッケージを変更する")                   step_extra_packages ;;
      "キャンセルして終了する")
        echo -e "\n  インストールを中断しました。"
        exit 0
        ;;
    esac

    # 修正後にサマリーを再表示
    show_summary
  done

  echo ""
  print_warn "この操作は取り消せません。ディスク ${CONFIG[disk]} の全データが完全に消去されます。"
  local final_confirm
  local tty_out tty_in; _resolve_tty tty_out tty_in
  echo -ne "  ${BOLD}${RED}実行する場合は大文字で YES と入力してください${RESET}: " > "$tty_out"
  read -r final_confirm < "$tty_in"
  if [[ "$final_confirm" != "YES" ]]; then
    echo -e "\n  インストールをキャンセルしました。"
    exit 0
  fi
  run_install
}

main "$@"
