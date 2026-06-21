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
  [extra_zram]="yes"
  [extra_pkgs]=""
  [font_pkgs]=""
  [font_setup_fontconfig]="no"
  [filesystem]="ext4"
  [power_mgmt]="none"
  [firewall]="no"
  [printing]="no"
  [yay]="no"
)

# パーティションデバイス名（nvme0n1 → nvme0n1p1, sda → sda1 など）
part_suffix() {
  local disk="$1"
  local num="$2"
  # /dev/ プレフィックスを除去して統一
  disk="${disk#/dev/}"
  # デバイス名の末尾が数字の場合 (例: nvme0n1, mmcblk0) は 'p' を挟む
  if [[ "$disk" =~ [0-9]$ ]]; then
    echo "/dev/${disk}p${num}"
  else
    echo "/dev/${disk}${num}"
  fi
}

# ============================================
# ユーティリティ関数
# ============================================

_optimize_pacman_conf() {
  local conf_path="$1"
  [[ ! -f "$conf_path" ]] && return 0
  # すでに設定されていないかチェックして二重適用を防ぐ
  if ! grep -q 'ILoveCandy' "$conf_path" 2>/dev/null; then
    sed -i 's/^#Color$/Color\nILoveCandy/' "$conf_path"
  fi
  if grep -q '^#ParallelDownloads' "$conf_path" 2>/dev/null; then
    sed -i 's/^#ParallelDownloads = 5$/ParallelDownloads = 5/' "$conf_path"
  fi
}

error_handler() {
  local parent_lineno="$1"
  local message="$2"
  local code="${3:-1}"

  # 正常終了 (0) またはシグナルによる中断 (130など) は何もしない
  if [[ "$code" -eq 0 || "$code" -eq 130 ]]; then
    exit "$code"
  fi

  echo -e "\n${RED}${BOLD}╔══════════════════════════════════════════╗${RESET}"
  echo -e "${RED}${BOLD}║       インストールが中断されました       ║${RESET}"
  echo -e "${RED}${BOLD}╚══════════════════════════════════════════╝${RESET}"
  echo -e "  エラーが発生したため、処理を中断しました。"
  echo -e "  行番号: ${parent_lineno} (終了ステータス: ${code})"
  [[ -n "$message" ]] && echo -e "  コマンド: ${message}"
  echo -e "\n  ${YELLOW}${BOLD}🛠 トラブルシューティングの手順:${RESET}"
  echo -e "  1. 詳細なエラー原因をログファイルで確認してください:"
  echo -e "     ${BOLD}cat /tmp/myarchinstall.log${RESET}"
  echo -e "  2. 中途半端にマウントされた状態を解除するには、以下を実行してください:"
  echo -e "     ${BOLD}umount -R /mnt 2>/dev/null || true${RESET}"
  echo -e "     ${BOLD}swapoff -a 2>/dev/null || true${RESET}"
  echo -e "  3. パーティションテーブルの破損などが発生した場合は、再実行することで"
  echo -e "     自動的にクリーン（sgdisk --zap-all）されてやり直せます。"
  echo -e "  4. インターネット接続の状態を確認してください（ping archlinux.org）。"
  echo -e "\n  解決しない場合は、上記ログの内容を控えてお問い合わせください。"
  exit "$code"
}

print_header() {
  clear
  echo -e "${CYAN}${BOLD}"
  echo "╔══════════════════════════════════════════╗"
  echo "║     myarchinstall - Arch インストーラー  ║"
  echo "╚══════════════════════════════════════════╝"
  echo -e "${RESET}"
}

print_step() {
  local title="$1"
  local clear_screen="${2:-no}"
  # 設定入力ステップなど、ユーザーの入力を伴う画面では一度クリアして
  # プロンプトが画面最下端ギリギリになるのを防ぐ
  if [[ "$clear_screen" == "yes" ]]; then
    clear
  fi
  echo -e "\n${BLUE}${BOLD}▶ ${title}${RESET}"
  echo -e "${BLUE}$(printf '─%.0s' {1..44})${RESET}"
}

print_ok()   { echo -e "  ${GREEN}✔${RESET} $1"; }
print_warn() { echo -e "  ${YELLOW}⚠${RESET} $1"; }
print_err()  { echo -e "  ${RED}✘${RESET} $1"; }

run_cmd() {
  # コマンドを実行しログに残す。失敗時はエラー表示して終了
  local desc="$1"; shift
  echo -ne "  ${CYAN}…${RESET} ${desc}..."
  if "$@" >> /tmp/myarchinstall.log 2>&1; then
    echo -e "\r  ${GREEN}✔${RESET} ${desc}   "
  else
    echo -e "\r  ${RED}✘${RESET} ${desc} — 失敗"
    # 直接エラーハンドラを呼び出し、詳細なトラブルシューティングを表示
    error_handler "${BASH_LINENO[0]}" "${desc}" 1
  fi
}

ask() {
  local prompt="$1"
  local default="${2:-}"
  local answer
  if [[ -n "$default" ]]; then
    echo -ne "  ${BOLD}${prompt}${RESET} [${default}]: " >&2
  else
    echo -ne "  ${BOLD}${prompt}${RESET}: " >&2
  fi
  read -r answer
  echo "${answer:-$default}"
}

ask_password() {
  local prompt="$1"
  local pw1 pw2
  while true; do
    echo -ne "  ${BOLD}${prompt}${RESET}: " >&2
    read -rs pw1; echo >&2
    if [[ -z "$pw1" ]]; then
      print_err "パスワードは空にできません。" >&2
      continue
    fi
    # パスワード強度（文字数）警告
    if [[ ${#pw1} -lt 8 ]]; then
      print_warn "警告: パスワードが短すぎます（8文字以上を強く推奨）。" >&2
    fi
    echo -ne "  ${BOLD}（確認）${prompt}${RESET}: " >&2
    read -rs pw2; echo >&2
    if [[ "$pw1" == "$pw2" ]]; then
      echo "$pw1"
      return
    fi
    print_err "パスワードが一致しません。もう一度入力してください。" >&2
  done
}

confirm() {
  local prompt="${1:-続けますか？}"
  local default="${2:-N}"
  local answer
  if [[ "$default" =~ ^[yY]$ ]]; then
    echo -ne "  ${BOLD}${prompt}${RESET} [Y/n]: "
  else
    echo -ne "  ${BOLD}${prompt}${RESET} [y/N]: "
  fi
  read -r answer
  answer="${answer:-$default}"
  if [[ "$answer" =~ ^[yY]$ ]]; then
    return 0
  else
    return 1
  fi
}

select_from_list() {
  local prompt="$1"
  shift
  local options=("$@")

  if [[ ${#options[@]} -eq 0 ]]; then
    print_err "選択肢がありません。" >&2
    exit 1
  fi

  echo -e "  ${BOLD}${prompt}${RESET}" >&2
  for i in "${!options[@]}"; do
    printf "    ${CYAN}%2d)${RESET} %s\n" "$((i+1))" "${options[$i]}" >&2
  done
  local choice
  while true; do
    echo -ne "  番号を入力 (q で終了): " >&2
    read -r choice
    if [[ "$choice" == "q" || "$choice" == "quit" || "$choice" == "exit" ]]; then
      print_err "インストールを中断し、終了します。" >&2
      kill -15 $$ 2>/dev/null || true
      exit 0
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
      echo "${options[$((choice-1))]}"
      return
    fi
    print_err "1〜${#options[@]} の番号、または q を入力してください。" >&2
  done
}

# ============================================
# ステップ 1: ディスク選択
# ============================================

step_disk() {
  print_step "ディスク選択" "yes"

  # フリーズ防止、耐障害性、速度向上のために、外部の lsblk コマンドへの依存を完全に廃止し、
  # Linux カーネルの /sys/block/ を直接スキャンします。
  # これにより、無応答なネットワークマウントや不安定なデバイスがあっても絶対にハングしません。

  # セクタ数から人間向けのサイズ文字列に変換するヘルパー関数
  _format_size() {
    local sectors="$1"
    local bytes=$(( sectors * 512 ))
    local kib=$(( bytes / 1024 ))
    local mib=$(( kib / 1024 ))
    local gib=$(( mib / 1024 ))
    
    if (( gib > 0 )); then
      local dec=$(( ((mib * 100 / 1024) + 5) / 10 % 10 ))
      echo "${gib}.${dec}G"
    elif (( mib > 0 )); then
      local dec=$(( ((kib * 100 / 1024) + 5) / 10 % 10 ))
      echo "${mib}.${dec}M"
    else
      echo "${kib}K"
    fi
  }

  while true; do
    local disks=()
    local devpath

    for devpath in /sys/block/*; do
      [[ ! -e "$devpath" ]] && continue
      local devname
      devname=$(basename "$devpath")

      # loop, sr, zram, ram デバイスを除外（これらはインストール先として選択不可）
      if [[ "$devname" =~ ^loop || "$devname" =~ ^sr || "$devname" =~ ^zram || "$devname" =~ ^ram ]]; then
        continue
      fi

      # サイズの取得 (セクタ数)
      local sectors=0
      if [[ -f "${devpath}/size" ]]; then
        sectors=$(cat "${devpath}/size" 2>/dev/null || echo 0)
      fi
      [[ "$sectors" -eq 0 ]] && continue

      local size_str
      size_str=$(_format_size "$sectors")

      # モデル名の取得
      local model=""
      if [[ -f "${devpath}/device/model" ]]; then
        model=$(cat "${devpath}/device/model" 2>/dev/null | xargs || true)
      fi

      # 接続タイプの判定 (readlink から判定)
      local link_target
      link_target=$(readlink "$devpath" 2>/dev/null || true)
      local tran=""
      if [[ "$link_target" =~ /usb[0-9]*/ || "$link_target" =~ /usb/ ]]; then
        tran="usb"
      elif [[ "$link_target" =~ /nvme/ ]]; then
        tran="nvme"
      elif [[ "$link_target" =~ /ata[0-9]*/ || "$link_target" =~ /ata/ ]]; then
        tran="sata"
      elif [[ "$link_target" =~ /virtio/ ]]; then
        tran="virtio"
      fi

      # 既存のパーティションのファイルシステムタイプを取得して表示名に添える（初心者見分け用）
      local parts=""
      local p
      for p in /sys/block/${devname}/${devname}*; do
        [[ ! -d "$p" ]] && continue
        local p_name
        p_name=$(basename "$p")
        # デバイス名と完全一致するものは除外（パーティションのみを対象）
        [[ "$p_name" == "$devname" ]] && continue
        local fstype
        fstype=$(blkid -s TYPE -o value "/dev/${p_name}" 2>/dev/null || true)
        if [[ -n "$fstype" ]]; then
          # 重複を排除して追加
          if [[ ! "$parts" =~ "$fstype" ]]; then
            parts="${parts:+$parts, }$fstype"
          fi
        fi
      done

      # 接続インターフェースのラベル
      local label=""
      case "$tran" in
        usb)  label=" [外付け USB]" ;;
        sata) label=" [SATA]" ;;
        nvme) label=" [NVMe]" ;;
        virtio) label=" [VirtIO]" ;;
        *)    [[ -n "$tran" ]] && label=" [${tran}]" ;;
      esac

      local display_name="/dev/${devname} (${size_str})"
      [[ -n "$model" ]] && display_name="${display_name} ${model}"
      [[ -n "$label" ]] && display_name="${display_name}${label}"
      [[ -n "$parts" ]] && display_name="${display_name} [既存: ${parts}]"

      disks+=("$display_name")
    done

    if [[ ${#disks[@]} -eq 0 ]]; then
      print_err "インストール先として使用可能なディスクが見つかりません。"
      echo -e "\n${CYAN}💡 ヒント: 内蔵ディスクが全く検出されていない場合、以下の可能性があります:${RESET}"
      echo "1. BIOS/UEFI の設定で SATA/NVMe モードが 'RAID' (Intel RST/VMD) になっている。"
      echo "   -> BIOS設定画面で 'AHCI' または 'NVMe' モード (RAID無効) に変更してください。"
      echo "2. ディスクが物理的に正しく接続されていない、または故障している。"
      exit 1
    fi

    echo ""
    local selected
    selected=$(select_from_list "インストール先ディスクを選択してください:" "${disks[@]}")
    CONFIG[disk]=$(echo "$selected" | awk '{print $1}')

    # 外付けディスクかどうかを記録（完了メッセージで案内するため）
    local chosen_name="${CONFIG[disk]#/dev/}"
    local chosen_link
    chosen_link=$(readlink "/sys/block/${chosen_name}" 2>/dev/null || true)
    if [[ "$chosen_link" =~ /usb[0-9]*/ || "$chosen_link" =~ /usb/ ]]; then
      CONFIG[disk_is_external]="yes"
      print_warn "外付け USB デバイスが選択されました"
    else
      CONFIG[disk_is_external]="no"
    fi

    print_warn "選択: ${CONFIG[disk]}"
    print_warn "このディスクの全データが消去されます！"

    if confirm "本当によろしいですか？"; then
      print_ok "ディスク: ${CONFIG[disk]}"
      break
    else
      print_warn "ディスク選択をやり直します。"
    fi
  done
}

# ============================================
# ステップ 2: パーティション構成
# ============================================

step_partition_scheme() {
  print_step "パーティション構成" "yes"

  # 選択したディスクが SSD (非回転) かどうかを判定
  local is_ssd="no"
  local devname="${CONFIG[disk]#/dev/}"
  if [[ -f "/sys/block/${devname}/queue/rotational" ]]; then
    if [[ "$(cat "/sys/block/${devname}/queue/rotational" 2>/dev/null)" == "0" ]]; then
      is_ssd="yes"
    fi
  fi

  local scheme
  if [[ "$is_ssd" == "yes" ]]; then
    print_warn "検出されたディスクは SSD/NVMe です。書き込み寿命保護のため、物理 swap なし ＋ zram 構成が強く推奨されます。"
  else
    print_warn "検出されたディスクは HDD（回転体）です。HDD 上の物理 swap はシステム全体の応答性を低下させるため、物理 swap なし ＋ zram 構成が推奨されます。"
  fi

  scheme=$(select_from_list "パーティション構成を選択してください:" \
    "自動（推奨） - EFI 512M(起動用) + / のみ（物理 swap なし、メモリ圧縮 zram 推奨）" \
    "自動 - EFI 512M(起動用) + swap 4G(予備領域) + /" \
    "手動（fdisk を起動）")

  case "$scheme" in
    *swap\ 4G*) CONFIG[partition_scheme]="auto_swap" ;;
    *swap\ なし*|*のみ*) CONFIG[partition_scheme]="auto_noswap" ;;
    *手動*)     CONFIG[partition_scheme]="manual" ;;
  esac
  print_ok "パーティション構成: ${CONFIG[partition_scheme]}"

  if [[ "${CONFIG[partition_scheme]}" != "manual" ]]; then
    echo ""
    local fs
    fs=$(select_from_list "root のファイルシステム:" \
      "ext4   - 安定・広く使われている（推奨）" \
      "btrfs  - スナップショット・圧縮・CoW 対応" \
      "xfs    - 高パフォーマンス・大容量向け")
    case "$fs" in
      "ext4   - 安定・広く使われている（推奨）")        CONFIG[filesystem]="ext4"  ;;
      "btrfs  - スナップショット・圧縮・CoW 対応") CONFIG[filesystem]="btrfs" ;;
      "xfs    - 高パフォーマンス・大容量向け")      CONFIG[filesystem]="xfs"   ;;
    esac
    print_ok "ファイルシステム: ${CONFIG[filesystem]}"
  else
    CONFIG[filesystem]="manual"
  fi
}

# ============================================
# ステップ 3: システム設定
# ============================================

step_system() {
  print_step "システム設定" "yes"

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
  while true; do
    local hn
    hn=$(ask "ホスト名" "archlinux")
    if [[ -z "$hn" ]]; then
      print_err "ホスト名は必須です。" >&2
      continue
    fi
    # 長さチェック
    if [[ ${#hn} -gt 63 ]]; then
      print_err "ホスト名は63文字以下にしてください。" >&2
      continue
    fi
    # 文字種チェック (英数字とハイフンのみ、先頭と末尾はハイフン不可)
    if [[ ! "$hn" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
      print_err "ホスト名は半角英数字とハイフンのみが使用でき、先頭と末尾にハイフンは使用できません。" >&2
      continue
    fi
    CONFIG[hostname]="$hn"
    break
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
}

# ============================================
# ステップ 4: ユーザー設定
# ============================================

step_users() {
  print_step "ユーザー設定" "yes"

  # --- root パスワード ---
  echo -e "  ${YELLOW}root パスワードを設定します${RESET}"
  local root_pw
  while true; do
    root_pw=$(ask_password "root パスワード")
    if [[ -z "$root_pw" ]]; then
      print_err "パスワードは空にできません。"
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
      if [[ -z "$upw" ]]; then
        print_err "パスワードは空にできません。"
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
  # efivarfs がマウントされていない場合があるため、チェックする前にマウントを試みる
  if [[ ! -d /sys/firmware/efi/efivars ]]; then
    modprobe efivarfs &>/dev/null || true
    mount -t efivarfs efivarfs /sys/firmware/efi/efivars &>/dev/null || true
  fi

  if [[ -d /sys/firmware/efi/efivars ]]; then
    echo "uefi"
  else
    echo "bios"
  fi
}

step_bootloader() {
  print_step "ブートローダー" "yes"

  # 自動検出
  local detected_mode
  detected_mode=$(detect_boot_mode)

  # ブートモードをユーザーに選択・確認させる（自動検出結果を提示）
  local mode_choice
  if [[ "$detected_mode" == "uefi" ]]; then
    mode_choice=$(select_from_list "ブートモードを選択してください（自動検出: UEFI）:" \
      "UEFI モード（自動検出・推奨）" \
      "BIOS (レガシー) モード")
  else
    mode_choice=$(select_from_list "ブートモードを選択してください（自動検出: BIOS）:" \
      "BIOS (レガシー) モード（自動検出）" \
      "UEFI モード")
  fi

  case "$mode_choice" in
    *UEFI*) CONFIG[boot_mode]="uefi" ;;
    *BIOS*) CONFIG[boot_mode]="bios" ;;
  esac

  if [[ "${CONFIG[boot_mode]}" == "uefi" ]]; then
    print_ok "ブートモード: UEFI"

    local bl
    bl=$(select_from_list "ブートローダーを選択:" \
      "systemd-boot（推奨・シンプル・起動が高速・追加パッケージ不要）" \
      "GRUB（高機能・他OSとの共存（デュアルブート）や特殊構成向け）")

    case "$bl" in
      *systemd-boot*) CONFIG[bootloader]="systemd-boot" ;;
      *GRUB*)         CONFIG[bootloader]="grub" ;;
    esac
  else
    print_ok "ブートモード: BIOS (レガシー)"
    print_warn "systemd-boot は UEFI 専用のため、GRUB を使用します。"
    CONFIG[bootloader]="grub"
  fi

  print_ok "ブートローダー: ${CONFIG[bootloader]}"
}

# ============================================
# ステップ 6: デスクトップ環境
# ============================================

step_desktop() {
  print_step "デスクトップ環境（任意）" "yes"

  local de
  de=$(select_from_list "デスクトップ環境を選択:" \
    "なし（最小構成・CLI）" \
    "KDE Plasma  - 高機能・Wayland/X11" \
    "GNOME       - シンプル・Wayland 推奨" \
    "Xfce        - 軽量・X11 安定" \
    "Budgie      - エレガント・Wayland 専用" \
    "COSMIC      - 新世代・Rust 製・Wayland" \
    "Sway        - タイル型 WM・Wayland" \
    "Hyprland    - アニメーション・タイル型・Wayland" \
    "Niri        - スクロール型タイル・Wayland")

  case "$de" in
    "なし（最小構成・CLI）")                      CONFIG[desktop]="none" ;;
    "KDE Plasma  - 高機能・Wayland/X11")          CONFIG[desktop]="kde" ;;
    "GNOME       - シンプル・Wayland 推奨")        CONFIG[desktop]="gnome" ;;
    "Xfce        - 軽量・X11 安定")               CONFIG[desktop]="xfce" ;;
    "Budgie      - エレガント・Wayland 専用")       CONFIG[desktop]="budgie" ;;
    "COSMIC      - 新世代・Rust 製・Wayland")       CONFIG[desktop]="cosmic" ;;
    "Sway        - タイル型 WM・Wayland")          CONFIG[desktop]="sway" ;;
    "Hyprland    - アニメーション・タイル型・Wayland") CONFIG[desktop]="hyprland" ;;
    "Niri        - スクロール型タイル・Wayland")    CONFIG[desktop]="niri" ;;
  esac

  # KDE のみ: アプリ規模を選択
  if [[ "${CONFIG[desktop]}" == "kde" ]]; then
    echo ""
    local kde_apps
    kde_apps=$(select_from_list "KDE アプリの規模を選択:" \
      "最小  - plasma-desktop のみ（約500MB）" \
      "標準  - plasma-meta + 基本アプリ（約1.5GB・推奨）" \
      "フル  - kde-applications-meta 全部入り（約4GB）")
    case "$kde_apps" in
      "最小  - plasma-desktop のみ（約500MB）")     CONFIG[kde_apps]="minimal" ;;
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
    gnome)
      local dm
      dm=$(select_from_list "ディスプレイマネージャー (DM) を選択:" \
        "GDM        - GNOME 推奨・Wayland 対応（推奨）" \
        "SDDM       - 軽量・Wayland/X11" \
        "LightDM    - 軽量・X11/Wayland" \
        "greetd     - 最軽量・TUI" \
        "なし       - TTY から手動起動")
      ;;
    budgie)
      local dm
      dm=$(select_from_list "ディスプレイマネージャー (DM) を選択:" \
        "SDDM       - 軽量・Budgie 推奨（推奨）" \
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

  # 先頭単語を小文字化してシンプルに判定（表示テキストの変更にも耐える設計）
  local dm_first_word="${dm%% *}"
  case "${dm_first_word,,}" in
    sddm)           CONFIG[dm]="sddm" ;;
    gdm)            CONFIG[dm]="gdm" ;;
    lightdm)        CONFIG[dm]="lightdm" ;;
    cosmic-greeter) CONFIG[dm]="cosmic-greeter" ;;
    greetd)         CONFIG[dm]="greetd" ;;
    なし|none)      CONFIG[dm]="none" ;;
    *)              CONFIG[dm]="none" ;;
  esac

  print_ok "DM: ${CONFIG[dm]}"
}

# ============================================
# ステップ: フォント選択
# ============================================

step_fonts() {
  print_step "フォント設定" "yes"

  CONFIG[font_pkgs]=""
  CONFIG[font_setup_fontconfig]="no"

  echo -e "  インストールするフォントを選択してください。\n"

  # ── Fira & Nerd Fonts ─────────────────────
  echo -e "  ${CYAN}${BOLD}[ Fira & Nerd Fonts ]${RESET}"
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

  # Nerd Fonts の追加提案
  local recommend_nerd=""
  if [[ "${CONFIG[desktop]}" =~ ^(sway|hyprland|niri)$ ]]; then
    recommend_nerd="（${CONFIG[desktop]} のバー・ターミナル表示に推奨）"
  fi

  if confirm "JetBrainsMono Nerd Font をインストールしますか？${recommend_nerd}"; then
    fira_pkgs+=(ttf-jetbrains-mono-nerd);  print_ok "ttf-jetbrains-mono-nerd"
  fi
  if confirm "FiraCode Nerd Font をインストールしますか？${recommend_nerd}"; then
    fira_pkgs+=(ttf-firacode-nerd);  print_ok "ttf-firacode-nerd"
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
  print_step "追加パッケージ設定" "yes"

  echo -e "  ${YELLOW}※ base-devel はデフォルトでインストールされません。${RESET}"
  echo -e "  ${YELLOW}  AUR（yay/paru）や自前ビルドが必要な場合のみ追加してください。${RESET}\n"

  CONFIG[extra_base_devel]="no"
  CONFIG[extra_zram]="yes"
  CONFIG[extra_pkgs]=""

  if confirm "base-devel を追加しますか？（gcc, make, binutils など AUR に必要）"; then
    CONFIG[extra_base_devel]="yes"
    print_ok "base-devel を追加"
  else
    print_ok "base-devel はスキップ（後から: pacman -S base-devel）"
  fi

  if confirm "zram を有効にしますか？（RAM 上の圧縮 swap・推奨）" "Y"; then
    CONFIG[extra_zram]="yes"
    print_ok "zram-generator を追加"
  else
    CONFIG[extra_zram]="no"
    print_ok "zram-generator はスキップ"
  fi

  # 電源管理
  echo ""
  CONFIG[power_mgmt]="none"
  if confirm "電源管理ツールをインストールしますか？（ノートPC 推奨）"; then
    local pm
    pm=$(select_from_list "電源管理ツール:" \
      "power-profiles-daemon（KDE/GNOME 統合・シンプル・推奨）" \
      "TLP（高機能・バッテリー最適化向け）")
    case "$pm" in
      "power-profiles-daemon（KDE/GNOME 統合・シンプル・推奨）") CONFIG[power_mgmt]="ppd" ;;
      "TLP（高機能・バッテリー最適化向け）")                      CONFIG[power_mgmt]="tlp" ;;
    esac
    print_ok "電源管理: ${CONFIG[power_mgmt]}"
  fi

  # ファイアウォール
  echo ""
  CONFIG[firewall]="no"
  if confirm "ファイアウォール（ufw）を有効にしますか？（推奨）"; then
    CONFIG[firewall]="yes"
    print_ok "ufw を有効化します"
  else
    print_ok "ファイアウォールはスキップ"
  fi

  # 印刷機能 (CUPS)
  echo ""
  CONFIG[printing]="no"
  if confirm "印刷機能（CUPS）をインストールしますか？"; then
    CONFIG[printing]="yes"
    print_ok "CUPS をインストールし、有効化します"
  else
    print_ok "印刷機能はスキップ"
  fi

  # AUR ヘルパー (yay)
  echo ""
  CONFIG[yay]="no"
  if confirm "AUR ヘルパー（yay）をインストールしますか？（一般ユーザー必須）"; then
    CONFIG[yay]="yes"
    print_ok "yay-bin をインストールします"
  else
    print_ok "yay はスキップ"
  fi

  local extra
  extra=$(ask "その他追加パッケージ（スペース区切り、不要なら空 Enter）" "")
  CONFIG[extra_pkgs]="$extra"
  if [[ -n "$extra" ]]; then
    print_ok "追加パッケージ: $extra"
  fi
}

# ============================================
# 設定サマリー表示
# ============================================

show_summary() {
  print_header
  print_step "インストール設定サマリー"

  echo -e "  ${BOLD}ディスク      :${RESET} ${CONFIG[disk]}"
  echo -e "  ${BOLD}パーティション :${RESET} ${CONFIG[partition_scheme]}"
  [[ "${CONFIG[filesystem]}" != "manual" ]] && \
    echo -e "  ${BOLD}ファイルシステム:${RESET} ${CONFIG[filesystem]}"
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
  echo -e "  ${BOLD}base-devel    :${RESET} ${CONFIG[extra_base_devel]}"
  echo -e "  ${BOLD}zram          :${RESET} ${CONFIG[extra_zram]}"
  [[ -n "${CONFIG[extra_pkgs]}" ]] && \
    echo -e "  ${BOLD}追加パッケージ :${RESET} ${CONFIG[extra_pkgs]}"
  [[ "${CONFIG[power_mgmt]:-none}" != "none" ]] && \
    echo -e "  ${BOLD}電源管理      :${RESET} ${CONFIG[power_mgmt]}"
  [[ "${CONFIG[firewall]:-no}" == "yes" ]] && \
    echo -e "  ${BOLD}ファイアウォール:${RESET} ufw（有効）"
  echo -e "  ${BOLD}印刷機能（CUPS）:${RESET} ${CONFIG[printing]}"
  echo -e "  ${BOLD}AUR ヘルパー   :${RESET} ${CONFIG[yay]}"
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

  # sgdisk が無ければ gptfdisk をインストール
  if ! command -v sgdisk &>/dev/null; then
    run_cmd "gptfdisk インストール" pacman -S --noconfirm gptfdisk
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
  run_cmd "udev 反映待ち" udevadm settle
}

# ============================================
# 実行: フォーマット & マウント
# ============================================

do_format_and_mount() {
  local disk="${CONFIG[disk]}"
  local scheme="${CONFIG[partition_scheme]}"
  local boot_mode="${CONFIG[boot_mode]}"

  print_step "フォーマット & マウント"

  # 前回の試行で残ったマウントを解除
  swapoff -a 2>/dev/null || true
  umount -R /mnt 2>/dev/null || true

  # 手動パーティションの場合はユーザーが自分でマウントする
  if [[ "$scheme" == "manual" ]]; then
    echo ""
    print_warn "手動パーティションモードです。"
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

  # ファイルシステムに応じた root フォーマット＆マウント
  _mount_root() {
    local part="$1"
    case "${CONFIG[filesystem]:-ext4}" in
      ext4)
        run_cmd "root フォーマット (ext4)"  mkfs.ext4 -F "$part"
        run_cmd "root マウント"              mount "$part" /mnt
        ;;
      btrfs)
        run_cmd "btrfs カーネルモジュール読み込み" modprobe btrfs
        run_cmd "root フォーマット (btrfs)" mkfs.btrfs -f "$part"
        run_cmd "btrfs 一時マウント"         mount -t btrfs "$part" /mnt
        run_cmd "@ サブボリューム作成"          btrfs subvolume create /mnt/@
        run_cmd "@home サブボリューム作成"      btrfs subvolume create /mnt/@home
        run_cmd "@snapshots サブボリューム作成" btrfs subvolume create /mnt/@snapshots
        run_cmd "@var_log サブボリューム作成"   btrfs subvolume create /mnt/@var_log
        run_cmd "btrfs 一時アンマウント"     umount /mnt
        local btrfs_opts="rw,noatime,compress=zstd"
        run_cmd "@ マウント"          mount -o "${btrfs_opts},subvol=@"           "$part" /mnt
        run_cmd "マウントポイント作成" bash -c "mkdir -p /mnt/home /mnt/.snapshots /mnt/var/log"
        run_cmd "@home マウント"      mount -o "${btrfs_opts},subvol=@home"       "$part" /mnt/home
        run_cmd "@snapshots マウント" mount -o "${btrfs_opts},subvol=@snapshots"  "$part" /mnt/.snapshots
        run_cmd "@var_log マウント"   mount -o "${btrfs_opts},subvol=@var_log"    "$part" /mnt/var/log
        print_ok "btrfs サブボリューム構成: @ @home @snapshots @var_log"
        ;;
      xfs)
        run_cmd "xfs カーネルモジュール読み込み" modprobe xfs
        run_cmd "root フォーマット (xfs)"   mkfs.xfs -f "$part"
        run_cmd "root マウント"              mount -t xfs "$part" /mnt
        ;;
    esac
  }

  if [[ "$boot_mode" == "uefi" ]]; then
    local efi_part root_part swap_part=""
    efi_part=$(part_suffix "$disk" 1)

    if [[ "$scheme" == "auto_swap" ]]; then
      swap_part=$(part_suffix "$disk" 2)
      root_part=$(part_suffix "$disk" 3)
    else
      root_part=$(part_suffix "$disk" 2)
    fi

    run_cmd "EFI フォーマット (FAT32)"  mkfs.fat -F32 "$efi_part"
    [[ -n "$swap_part" ]] && run_cmd "swap フォーマット" mkswap "$swap_part"
    _mount_root "$root_part"
    run_cmd "EFI ディレクトリ作成" mkdir -p /mnt/boot
    run_cmd "EFI マウント"         mount -o fmask=0077,dmask=0077 "$efi_part" /mnt/boot
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

    [[ -n "$swap_part" ]] && run_cmd "swap フォーマット" mkswap "$swap_part"
    _mount_root "$root_part"
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
    echo "           （※パスワードを求められたら入力して Enter）"
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
  timedatectl set-ntp true 2>/dev/null || true
  # 最大10秒待って同期を確認
  local i
  for i in {1..10}; do
    if LC_ALL=C timedatectl status 2>/dev/null | grep -qi "synchronized: yes"; then
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
  print_step "ネットワーク設定" "yes"

  # WiFi バックエンド選択
  local wifi_backend
  wifi_backend=$(select_from_list "WiFi バックエンドを選択:" \
    "wpa_supplicant（長年の実績あり・ほぼすべての WiFi 機器に対応）" \
    "iwd（新世代・高速・推奨）" \
    "なし（有線のみ・後から設定）")

  case "$wifi_backend" in
    *wpa_supplicant*) CONFIG[wifi_backend]="wpa_supplicant" ;;
    *iwd*)            CONFIG[wifi_backend]="iwd" ;;
    *)                CONFIG[wifi_backend]="none" ;;
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
  print_step "ミラーサーバー設定" "yes"

  local choice
  choice=$(select_from_list "ミラーサーバーの選択方法:" \
    "自動（reflector で日本の速いサーバーを自動選択・推奨）" \
    "日本のミラーを手動で選ぶ" \
    "現在の設定をそのまま使う")

  case "$choice" in
    "自動（reflector で日本の速いサーバーを自動選択・推奨）")
      CONFIG[mirror_mode]="auto"
      print_ok "reflector で日本のミラーを自動選択します"
      ;;
    "日本のミラーを手動で選ぶ")
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
      # 日本のミラーから HTTPS・最終同期24時間以内・速度順 上位8件
      run_cmd "reflector 実行（日本・速度順）" \
        reflector \
          --country Japan \
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
  # パッケージデータベース更新（失敗時は reflector による自動切り替え＆リトライ）
  local db_ok=no
  local db_attempt
  for db_attempt in 1 2; do
    echo -ne "  ${CYAN}…${RESET} パッケージデータベース更新..."
    if pacman -Sy --noconfirm >> /tmp/myarchinstall.log 2>&1; then
      echo -e "\r  ${GREEN}✔${RESET} パッケージデータベース更新                       "
      db_ok=yes

      # 署名エラー防止のため、まずキーリングパッケージ自体を最新にする
      echo -ne "  ${CYAN}…${RESET} キーリングパッケージ更新..."
      if pacman -Sy --noconfirm archlinux-keyring >> /tmp/myarchinstall.log 2>&1; then
        echo -e "\r  ${GREEN}✔${RESET} キーリングパッケージ更新                       "
      else
        echo -e "\r  ${YELLOW}⚠${RESET} キーリングパッケージ更新（失敗、無視して続行） "
      fi
      break
    else
      echo -e "\r  ${RED}✘${RESET} パッケージデータベース更新 — 失敗 (試行 ${db_attempt}/2)"
      if [[ $db_attempt -eq 1 ]]; then
        print_warn "ミラーが接続不能または遅い可能性があります。reflector で最速ミラーに切り替えて再試行します..."
        if ! command -v reflector &>/dev/null; then
          pacman -S --noconfirm reflector >> /tmp/myarchinstall.log 2>&1 || true
        fi
        if reflector --country Japan --protocol https --age 24 --sort rate --number 8 \
             --save /etc/pacman.d/mirrorlist >> /tmp/myarchinstall.log 2>&1; then
          print_ok "ミラーを更新しました（再試行します）"
        else
          print_warn "reflector 失敗。そのまま再試行します"
        fi
      fi
    fi
  done

  if [[ "$db_ok" != "yes" ]]; then
    print_err "パッケージデータベースの更新に失敗しました。ログ: /tmp/myarchinstall.log"
    error_handler "${BASH_LINENO[0]}" "パッケージデータベース更新" 1
  fi

  local pkgs=(base sudo linux linux-firmware networkmanager vim ttf-nerd-fonts-symbols woff2-font-awesome pacman-contrib)

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

  # GRUB 選択時は追加パッケージ
  if [[ "${CONFIG[bootloader]}" == "grub" ]]; then
    pkgs+=(grub efibootmgr)
  fi

  # ユーザーが選択した追加パッケージ
  [[ "${CONFIG[extra_base_devel]}" == "yes" ]] && pkgs+=(base-devel)
  [[ "${CONFIG[extra_zram]}" == "yes" ]]       && pkgs+=(zram-generator)
  if [[ -n "${CONFIG[extra_pkgs]}" ]]; then
    read -ra _extra <<< "${CONFIG[extra_pkgs]}"
    pkgs+=("${_extra[@]}")
  fi

  # 追加パッケージに合わせた日本語化パッケージ（Firefox/LibreOffice等）の自動付与
  if [[ "${CONFIG[japanese_env]}" == "yes" ]]; then
    if [[ "${CONFIG[extra_pkgs]}" =~ firefox ]]; then
      pkgs+=(firefox-i18n-ja)
    fi
    if [[ "${CONFIG[extra_pkgs]}" =~ libreoffice-fresh ]]; then
      pkgs+=(libreoffice-fresh-ja)
    elif [[ "${CONFIG[extra_pkgs]}" =~ libreoffice-still ]]; then
      pkgs+=(libreoffice-still-ja)
    fi
  fi

  # フォント
  if [[ -n "${CONFIG[font_pkgs]}" ]]; then
    read -ra _font_pkgs <<< "${CONFIG[font_pkgs]}"
    pkgs+=("${_font_pkgs[@]}")
  fi

  # IME
  case "${CONFIG[jp_ime]}" in
    fcitx5-mozc)
      pkgs+=(fcitx5 fcitx5-mozc fcitx5-gtk fcitx5-qt fcitx5-configtool fcitx5-material-color fcitx5-nord fcitx5-breeze) ;;
    fcitx5-anthy)
      pkgs+=(fcitx5 fcitx5-anthy fcitx5-gtk fcitx5-qt fcitx5-configtool fcitx5-material-color fcitx5-nord fcitx5-breeze) ;;
    ibus-mozc)
      pkgs+=(ibus ibus-mozc) ;;
  esac

  # 日本語環境用ユーティリティ（ZIPの日本語文字化け防止、日本語manページ等）
  if [[ "${CONFIG[japanese_env]}" == "yes" ]]; then
    pkgs+=(unar man-db man-pages-ja)
  fi

  # ファイルシステムツール
  case "${CONFIG[filesystem]:-ext4}" in
    btrfs) pkgs+=(btrfs-progs) ;;
    xfs)   pkgs+=(xfsprogs) ;;
  esac

  # 電源管理パッケージ
  case "${CONFIG[power_mgmt]:-none}" in
    ppd) pkgs+=(power-profiles-daemon) ;;
    tlp) pkgs+=(tlp tlp-rdw) ;;
  esac

  # 印刷機能
  if [[ "${CONFIG[printing]:-no}" == "yes" ]]; then
    pkgs+=(cups cups-pdf nss-mdns avahi)
    if [[ "${CONFIG[desktop]}" != "none" ]]; then
      pkgs+=(system-config-printer)
    fi
  fi

  # プログレスバー付き pacstrap 実行
  # pkgs をバックグラウンドで pacstrap に渡しつつ、ログを監視して進捗を表示する
  _run_pacstrap_with_progress() {
    pacstrap /mnt "$@" >> /tmp/myarchinstall.log 2>&1 &
    local pid=$!
    local spin_idx=0
    local spin_chars=('-' $'\\' '|' '/')

    while kill -0 "$pid" 2>/dev/null; do
      local spin="${spin_chars[$spin_idx]}"
      spin_idx=$(( (spin_idx + 1) % 4 ))

      # ログから "(現在/合計)" パターンを取得してインストール進捗を計算
      local last_inst=""
      last_inst=$(grep -oE '\(\s*[0-9]+/[0-9]+\)' /tmp/myarchinstall.log 2>/dev/null \
                  | tail -1 | tr -d ' ()') || last_inst=""

      if [[ -n "$last_inst" ]]; then
        local cur="${last_inst%/*}" total="${last_inst#*/}"
        if [[ "${total:-0}" -gt 0 ]]; then
          local pct=$(( cur * 100 / total ))
          local bar_len=24
          local filled=$(( cur * bar_len / total ))
          local bar="" i
          for ((i=0; i<filled; i++));       do bar+="█"; done
          for ((i=filled; i<bar_len; i++)); do bar+="░"; done
          printf "\r  ${CYAN}%s${RESET} インストール中 [${GREEN}%s${RESET}] %3d%% (%s/%s 個)  " \
            "$spin" "$bar" "$pct" "$cur" "$total"
        fi
      elif grep -q 'Retrieving\|downloading' /tmp/myarchinstall.log 2>/dev/null; then
        printf "\r  ${CYAN}%s${RESET} ダウンロード中...                                    " "$spin"
      else
        printf "\r  ${CYAN}%s${RESET} 準備中...                                            " "$spin"
      fi

      sleep 0.2
    done

    wait "$pid"
  }

  local attempt
  for attempt in 1 2; do
    echo ""
    if _run_pacstrap_with_progress "${pkgs[@]}"; then
      printf "\r  ${GREEN}✔${RESET} pacstrap 完了                                          \n"
      break
    fi
    printf "\r  ${RED}✘${RESET} pacstrap 失敗（試行 %d/2）\n" "$attempt"
    if [[ $attempt -eq 1 ]]; then
      print_warn "ミラーが遅い可能性があります。reflector で最速ミラーに切り替えて再試行します..."
      if ! command -v reflector &>/dev/null; then
        pacman -S --noconfirm reflector >> /tmp/myarchinstall.log 2>&1 || true
      fi
      if reflector --country Japan --protocol https --age 24 --sort rate --number 8 \
           --save /etc/pacman.d/mirrorlist >> /tmp/myarchinstall.log 2>&1; then
        print_ok "ミラーを更新しました（再試行します）"
      else
        print_warn "reflector 失敗。そのまま再試行します"
      fi
    else
      print_err "pacstrap が 2 回失敗しました。ログ: /tmp/myarchinstall.log"
      exit 1
    fi
  done
}

# ============================================
# 実行: fstab
# ============================================

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
      arch-chroot /mnt bash -c "hwclock --systohc --localtime || true"
    run_cmd "adjtime LOCAL 設定" bash -c \
      "sed -i 's/^UTC$/LOCAL/' /mnt/etc/adjtime 2>/dev/null || \
       printf 'LOCAL\n0\n0\n' >> /mnt/etc/adjtime"
  else
    # 通常: RTC を UTC として扱う（推奨）
    run_cmd "RTC UTC 設定" arch-chroot /mnt bash -c "hwclock --systohc --utc || true"
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
    bash -c "sed -i -E 's/^#\s*(${locale_escaped}\s+)/\1/' /mnt/etc/locale.gen"
  # en_US.UTF-8 は常に有効にしておく（一部ツールに必要）
  run_cmd "en_US.UTF-8 有効化" \
    bash -c "sed -i 's/^#en_US\\.UTF-8/en_US.UTF-8/' /mnt/etc/locale.gen"
  run_cmd "locale-gen 実行" arch-chroot /mnt locale-gen
  run_cmd "LANG 設定" \
    bash -c "echo 'LANG=${CONFIG[locale]}' > /mnt/etc/locale.conf"
  run_cmd "キーマップ設定" \
    bash -c "echo 'KEYMAP=${CONFIG[keymap]}' > /mnt/etc/vconsole.conf"

  # ホームディレクトリのデフォルトフォルダ（Desktop等）を英語名で固定（端末での移動を快適にするため）
  if [[ "${CONFIG[japanese_env]}" == "yes" ]]; then
    run_cmd "ホームディレクトリ英語固定設定" bash -c "
      mkdir -p /mnt/etc/skel/.config
      cat > /mnt/etc/skel/.config/user-dirs.dirs << 'EOF'
XDG_DESKTOP_DIR=\"\$HOME/Desktop\"
XDG_DOWNLOAD_DIR=\"\$HOME/Downloads\"
XDG_TEMPLATES_DIR=\"\$HOME/Templates\"
XDG_PUBLICSHARE_DIR=\"\$HOME/Public\"
XDG_DOCUMENTS_DIR=\"\$HOME/Documents\"
XDG_MUSIC_DIR=\"\$HOME/Music\"
XDG_PICTURES_DIR=\"\$HOME/Pictures\"
XDG_VIDEOS_DIR=\"\$HOME/Videos\"
EOF
      echo 'C' > /mnt/etc/skel/.config/user-dirs.locale
    "
  fi

  # X11/Wayland キーボードレイアウト設定
  local xkb_layout xkb_model
  case "${CONFIG[keymap]}" in
    jp106) xkb_layout="jp";  xkb_model="jp106" ;;
    us)    xkb_layout="us";  xkb_model="pc105" ;;
    uk)    xkb_layout="gb";  xkb_model="pc105" ;;
    *)     xkb_layout="${CONFIG[keymap]}"; xkb_model="pc105" ;;
  esac
  run_cmd "X11 キーボードレイアウト設定" bash -c "mkdir -p /mnt/etc/X11/xorg.conf.d && cat > /mnt/etc/X11/xorg.conf.d/00-keyboard.conf << EOF
Section \"InputClass\"
    Identifier \"system-keyboard\"
    MatchIsKeyboard \"on\"
    Option \"XkbLayout\" \"${xkb_layout}\"
    Option \"XkbModel\" \"${xkb_model}\"
EndSection
EOF"

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
    run_cmd "resolv.conf バインドマウント解除" \
      bash -c "umount /mnt/etc/resolv.conf 2>/dev/null || true"
    run_cmd "resolv.conf シンボリックリンク設定" \
      bash -c "rm -f /mnt/etc/resolv.conf && \
        ln -sf /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf"
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

    # fcitx5 自動起動設定（DE 共通: XDG autostart）
    case "${CONFIG[jp_ime]}" in
      fcitx5-mozc|fcitx5-anthy)
        run_cmd "fcitx5 XDG autostart 設定" bash -c "
          mkdir -p /mnt/etc/xdg/autostart
          if [[ -f /mnt/usr/share/applications/fcitx5.desktop ]]; then
            cp /mnt/usr/share/applications/fcitx5.desktop /mnt/etc/xdg/autostart/fcitx5.desktop
          else
            cat > /mnt/etc/xdg/autostart/fcitx5.desktop << 'DEOF'
[Desktop Entry]
Name=Fcitx5
Exec=fcitx5 -d --replace
Icon=fcitx5
Terminal=false
Type=Application
Categories=System;Utility;
NoDisplay=true
DEOF
          fi
        "

        ;;
    esac
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

  # SSD TRIM タイマー（SSD の寿命維持・HDD では無害）
  run_cmd "SSD TRIM タイマー有効化" arch-chroot /mnt systemctl enable fstrim.timer

  # 電源管理サービス有効化
  case "${CONFIG[power_mgmt]:-none}" in
    ppd) run_cmd "power-profiles-daemon 有効化" \
           arch-chroot /mnt systemctl enable power-profiles-daemon ;;
    tlp) run_cmd "TLP 有効化" arch-chroot /mnt systemctl enable tlp ;;
  esac

  # ファイアウォール（ufw）
  if [[ "${CONFIG[firewall]:-no}" == "yes" ]]; then
    run_cmd "ufw インストール" arch-chroot /mnt pacman -S --noconfirm ufw
    run_cmd "ufw デフォルトルール設定" \
      arch-chroot /mnt bash -c "ufw default deny incoming; ufw default allow outgoing"
    run_cmd "ufw サービス有効化" arch-chroot /mnt systemctl enable ufw
    
    # 初心者向け：ローカルサービスが遮断されないよう自動で許可
    if [[ "${CONFIG[printing]:-no}" == "yes" ]]; then
      run_cmd "ufw 印刷サービス（IPP）許可" arch-chroot /mnt ufw allow ipp
    fi
    if [[ "${CONFIG[desktop]}" == "kde" && "${CONFIG[kde_apps]}" =~ ^(standard|full)$ ]]; then
      run_cmd "ufw KDE Connect 許可" arch-chroot /mnt bash -c "
        ufw allow 1714:1764/udp
        ufw allow 1714:1764/tcp
      "
    fi
    print_ok "ufw: 着信拒否・発信許可（デフォルト、プリンタ/KDE Connect自動許可）"
  fi

  # CUPS / Avahi サービス有効化 & nsswitch.conf 編集
  if [[ "${CONFIG[printing]:-no}" == "yes" ]]; then
    run_cmd "CUPS サービス有効化" arch-chroot /mnt systemctl enable cups
    run_cmd "Avahi サービス有効化" arch-chroot /mnt systemctl enable avahi-daemon
    run_cmd "nsswitch.conf mdns 設定" \
      bash -c "sed -i -E 's/^(hosts:\s+.*)\s+dns/\1 mdns_minimal [NOTFOUND=return] dns/' /mnt/etc/nsswitch.conf"
  fi

  # Fcitx5 デフォルト設定（スキン ＆ 入力メソッドの Mozc/Anthy 自動追加）
  if [[ "${CONFIG[jp_ime]:-none}" =~ ^fcitx5 ]]; then
    # スキン設定
    run_cmd "Fcitx5 テーマ設定" bash -c "
      mkdir -p /mnt/etc/skel/.config/fcitx5/conf
      cat > /mnt/etc/skel/.config/fcitx5/conf/classicui.conf << 'EOF'
UsePixelSize=True
Theme=breeze-opaque-dark-blue
EOF
    "

    # 入力メソッド (IME) プリセット設定
    local im_engine="mozc"
    if [[ "${CONFIG[jp_ime]}" == "fcitx5-anthy" ]]; then
      im_engine="anthy"
    fi

    run_cmd "Fcitx5 入力メソッド設定" bash -c "
      mkdir -p /mnt/etc/skel/.config/fcitx5
      cat > /mnt/etc/skel/.config/fcitx5/profile << EOF
[Groups/0]
Name=Default
Default Layout=jp
DefaultIM=${im_engine}

[Groups/0/Items/0]
Name=keyboard-jp
Layout=

[Groups/0/Items/1]
Name=${im_engine}
Layout=

[GroupList]
0=Default
EOF
    "
  fi

  # systemd-journald ログサイズ制限設定 (200MB)
  run_cmd "systemd-journald ログサイズ制限設定" bash -c "
    mkdir -p /mnt/etc/systemd
    if [ -f /mnt/etc/systemd/journald.conf ]; then
      sed -i 's/^#\?SystemMaxUse=.*$/SystemMaxUse=200M/' /mnt/etc/systemd/journald.conf
      if ! grep -q '^SystemMaxUse=' /mnt/etc/systemd/journald.conf; then
        sed -i '/^\[Journal\]/a SystemMaxUse=200M' /mnt/etc/systemd/journald.conf
      fi
    else
      echo -e '[Journal]\nSystemMaxUse=200M' > /mnt/etc/systemd/journald.conf
    fi
  "

  # pacman キャッシュ自動クリーンタイマー有効化 (pacman-contrib の paccache.timer)
  run_cmd "paccache.timer 有効化" arch-chroot /mnt systemctl enable paccache.timer

  # zram 向け swappiness 最適化設定
  if [[ "${CONFIG[extra_zram]}" == "yes" ]]; then
    run_cmd "zram swappiness 最適化設定" bash -c "
      mkdir -p /mnt/etc/sysctl.d
      echo 'vm.swappiness = 180' > /mnt/etc/sysctl.d/99-swappiness.conf
    "
  fi

  # pacman.conf ＆ makepkg.conf 最適化
  run_cmd "pacman.conf 高速化・カラー化" _optimize_pacman_conf /mnt/etc/pacman.conf
  run_cmd "makepkg.conf 並列ビルド設定" bash -c \
    "sed -i -E 's/^#?MAKEFLAGS=\"-j[0-9]+\"/MAKEFLAGS=\"-j\$(nproc)\"/' /mnt/etc/makepkg.conf"
}

# ============================================
# 実行: ユーザー設定
# ============================================

do_users() {
  print_step "ユーザー設定"

  # パスワード設定ヘルパー（特殊文字対応）
  # echo 'user:pass' だとシングルクォートが含まれると壊れるため
  # printf + 一時ファイル経由で渡す
  _set_password() {
    local target="$1"
    local pw="$2"
    local tmpfile
    tmpfile=$(mktemp /tmp/pw_XXXXXX)
    printf '%s:%s\n' "$target" "$pw" > "$tmpfile"
    arch-chroot /mnt chpasswd < "$tmpfile"
    rm -f "$tmpfile"
  }

  # root パスワード
  run_cmd "root パスワード設定" _set_password "root" "${CONFIG[root_password]}"

  # 追加シェルのインストール（必要なものだけ）
  local need_zsh=0 need_fish=0
  while IFS='|' read -r _ _ _ ushell _; do
    [[ "$ushell" == "zsh" ]]  && need_zsh=1
    [[ "$ushell" == "fish" ]] && need_fish=1
  done <<< "${CONFIG[users]}"
  [[ $need_zsh  -eq 1 ]] && run_cmd "zsh インストール"  arch-chroot /mnt pacman -S --noconfirm zsh
  [[ $need_fish -eq 1 ]] && run_cmd "fish インストール" arch-chroot /mnt pacman -S --noconfirm fish

  # sudo の設定（wheel グループ）
  # 通常 sudo と NOPASSWD を両立するため別行で設定
  local has_sudo=0 has_nopasswd=0
  while IFS='|' read -r _ _ usudo _ _; do
    [[ "$usudo" == "yes" ]]      && has_sudo=1
    [[ "$usudo" == "nopasswd" ]] && has_nopasswd=1
  done <<< "${CONFIG[users]}"

  if [[ $has_sudo -eq 1 ]]; then
    run_cmd "sudo 設定（wheel・パスワードあり）" \
      bash -c "sed -i 's/^# %wheel ALL=(ALL:ALL) ALL$/%wheel ALL=(ALL:ALL) ALL/' /mnt/etc/sudoers"
  fi
  if [[ $has_nopasswd -eq 1 ]]; then
    run_cmd "sudo 設定（wheel・NOPASSWD）" \
      bash -c "sed -i 's/^# %wheel ALL=(ALL:ALL) NOPASSWD: ALL$/%wheel ALL=(ALL:ALL) NOPASSWD: ALL/' /mnt/etc/sudoers"
  fi
  
  # sudo 実行時のパスワード入力フィードバック（アスタリスク表示）設定
  if [[ $has_sudo -eq 1 || $has_nopasswd -eq 1 ]]; then
    run_cmd "sudo パスワードフィードバック設定" bash -c \
      "mkdir -p /mnt/etc/sudoers.d && echo 'Defaults pwfeedback' > /mnt/etc/sudoers.d/pwfeedback && chmod 0440 /mnt/etc/sudoers.d/pwfeedback"
  fi

  # 一般ユーザーの作成
  if [[ -z "${CONFIG[users]}" ]]; then
    print_warn "一般ユーザーなし（root のみ）"
    return
  fi

  while IFS='|' read -r uname upw usudo ushell ugroups; do
    [[ -z "$uname" ]] && continue

    local shell_path="/bin/${ushell}"
    [[ "$ushell" == "fish" ]] && shell_path="/usr/bin/fish"
    [[ "$ushell" == "zsh"  ]] && shell_path="/usr/bin/zsh"

    run_cmd "ユーザー作成: ${uname}" \
      arch-chroot /mnt useradd \
        -m \
        -G "${ugroups}" \
        -s "${shell_path}" \
        "${uname}"

    run_cmd "${uname} パスワード設定" _set_password "${uname}" "${upw}"

    # NOPASSWD ユーザーは個別 sudoers ファイルで上書き
    if [[ "$usudo" == "nopasswd" ]]; then
      run_cmd "${uname} NOPASSWD 設定" bash -c \
        "echo '${uname} ALL=(ALL:ALL) NOPASSWD: ALL' > /mnt/etc/sudoers.d/${uname} && \
         chmod 0440 /mnt/etc/sudoers.d/${uname}"
    fi

    print_ok "作成: ${uname}（shell: ${ushell}, sudo: ${usudo}）"
  done <<< "${CONFIG[users]}"
}

# ============================================
# 実行: ブートローダー
# ============================================

do_bootloader() {
  print_step "ブートローダーのインストール"

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

    # root パーティションの PARTUUID を取得
    local disk="${CONFIG[disk]}"
    local scheme="${CONFIG[partition_scheme]}"
    local root_part

    if [[ "$scheme" == "manual" ]]; then
      root_part=$(findmnt -no SOURCE /mnt || true)
      if [[ -z "$root_part" ]]; then
        print_err "/mnt のマウント元デバイスを検出できませんでした。"
        exit 1
      fi
    elif [[ "$scheme" == "auto_swap" ]]; then
      root_part=$(part_suffix "$disk" 3)
    else
      root_part=$(part_suffix "$disk" 2)
    fi

    # (BIOSモード判定は事前ステップで完了しており、UEFI時のみここに到達します)

    local root_opts
    local root_partuuid
    root_partuuid=$(blkid -s PARTUUID -o value "$root_part" || true)
    if [[ -n "$root_partuuid" ]]; then
      root_opts="root=PARTUUID=${root_partuuid}"
    else
      # PARTUUID がない場合は UUID、それもなければデバイス名を直接指定
      local root_uuid
      root_uuid=$(blkid -s UUID -o value "$root_part" || true)
      if [[ -n "$root_uuid" ]]; then
        root_opts="root=UUID=${root_uuid}"
      else
        root_opts="root=${root_part}"
      fi
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
options ${root_opts} rw quiet
EOF"

    # フォールバックエントリ
    run_cmd "arch-fallback.conf 作成" bash -c "cat > /mnt/boot/loader/entries/arch-fallback.conf << EOF
title   Arch Linux (fallback)
linux   /vmlinuz-linux
${ucode_line}initrd  /initramfs-linux-fallback.img
options ${root_opts} rw
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
    run_cmd "grub.cfg 生成" \
      arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
  fi
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
  )

  case "${CONFIG[desktop]}" in
    kde)
      local pkgs=()
      case "${CONFIG[kde_apps]}" in
        minimal)  pkgs+=(plasma-desktop
                         plasma-pa plasma-nm bluedevil
                         dolphin konsole
                         kate ark okular gwenview) ;;
        standard) pkgs+=(plasma-meta
                         dolphin konsole kate ark spectacle
                         gwenview okular kdeconnect) ;;
        full)     pkgs+=(plasma-meta kde-applications-meta) ;;
      esac
      run_cmd "KDE Plasma インストール" \
        arch-chroot /mnt pacman -S --noconfirm "${pkgs[@]}" "${desktop_common_pkgs[@]}"
      ;;

    gnome)
      local pkgs=(gnome gnome-extra)
      run_cmd "GNOME インストール" \
        arch-chroot /mnt pacman -S --noconfirm "${pkgs[@]}" "${desktop_common_pkgs[@]}"

      # GNOME向けの日本語入力設定 (gsettings override)
      if [[ "${CONFIG[japanese_env]}" == "yes" ]]; then
        local gnome_override_dir="/mnt/usr/share/glib-2.0/schemas"
        run_cmd "GNOMEスキーマディレクトリ作成" mkdir -p "$gnome_override_dir"
        
        local sources_val="[('xkb', 'jp')]"
        if [[ "${CONFIG[jp_ime]}" == "ibus-mozc" ]]; then
          sources_val="[('xkb', 'jp'), ('ibus', 'mozc')]"
        fi

        run_cmd "GNOMEスキーマオーバーライド設定" bash -c "cat > ${gnome_override_dir}/90_myarchinstall.gschema.override << EOF
[org.gnome.desktop.input-sources]
sources=${sources_val}
show-all-sources=true
EOF"
        run_cmd "GNOMEスキーマコンパイル" arch-chroot /mnt glib-compile-schemas /usr/share/glib-2.0/schemas
      fi
      ;;

    xfce)
      local pkgs=(xfce4 xfce4-goodies
                  xorg-server xorg-xinit
                  network-manager-applet
                  pavucontrol
                  blueman
                  mousepad ristretto xarchiver atril mpv)
      run_cmd "Xfce インストール" \
        arch-chroot /mnt pacman -S --noconfirm "${pkgs[@]}" "${desktop_common_pkgs[@]}"
      ;;

    budgie)
      local pkgs=(budgie
                  budgie-control-center
                  budgie-extras
                  nautilus file-roller
                  gnome-terminal
                  gnome-keyring
                  network-manager-applet
                  gnome-text-editor eog evince mpv)
      run_cmd "Budgie インストール" \
        arch-chroot /mnt pacman -S --noconfirm "${pkgs[@]}" "${desktop_common_pkgs[@]}"
      print_ok "Budgie 10.10+ (Wayland 専用)"
      print_warn "mutter/gnome-settings-daemon は Budgie の依存パッケージのため同時にインストールされます（正常）"
      ;;

    cosmic)
      local pkgs=(cosmic
                  gnome-text-editor eog evince mpv file-roller)
      run_cmd "COSMIC インストール" \
        arch-chroot /mnt pacman -S --noconfirm "${pkgs[@]}" "${desktop_common_pkgs[@]}"
      print_ok "COSMIC 1.0 (Epoch)"
      ;;

    sway)
      local pkgs=(sway swaybg swayidle swaylock
                  waybar wofi foot
                  xwayland
                  xdg-desktop-portal-wlr xdg-desktop-portal-gtk
                  blueman
                  network-manager-applet
                  grim slurp wl-clipboard
                  mako
                  brightnessctl
                  thunar
                  mousepad imv zathura zathura-pdf-mupdf mpv xarchiver)
      run_cmd "Sway インストール" \
        arch-chroot /mnt pacman -S --noconfirm "${pkgs[@]}" "${desktop_common_pkgs[@]}"
      run_cmd "Sway デフォルト設定をコピー" bash -c "
        mkdir -p /mnt/etc/skel/.config/sway
        cp /mnt/usr/share/doc/sway/config /mnt/etc/skel/.config/sway/config 2>/dev/null || true
      "
      # 自動起動設定（nm-appletの追加）
      run_cmd "Sway: nm-applet 自動起動設定" bash -c "
        echo 'exec nm-applet --indicator' >> /mnt/etc/skel/.config/sway/config
      "
      if [[ "${CONFIG[jp_ime]:-none}" =~ ^fcitx5 ]]; then
        run_cmd "Sway: fcitx5 自動起動設定" bash -c "
          echo 'exec fcitx5 -d' >> /mnt/etc/skel/.config/sway/config
        "
      fi
      ;;

    hyprland)
      local pkgs=(hyprland hyprpaper hyprlock hypridle
                  waybar wofi kitty
                  xwayland
                  xdg-desktop-portal-hyprland xdg-desktop-portal-gtk
                  blueman
                  network-manager-applet
                  grim slurp wl-clipboard
                  mako
                  brightnessctl
                  thunar
                  mousepad imv zathura zathura-pdf-mupdf mpv xarchiver)
      run_cmd "Hyprland インストール" \
        arch-chroot /mnt pacman -S --noconfirm "${pkgs[@]}" "${desktop_common_pkgs[@]}"

      # デフォルト設定ファイルのコピー（自動生成の不具合防止）
      run_cmd "Hyprland デフォルト設定コピー" bash -c "
        mkdir -p /mnt/etc/skel/.config/hypr
        if [ -f /mnt/usr/share/hypr/hyprland.conf ]; then
          cp /mnt/usr/share/hypr/hyprland.conf /mnt/etc/skel/.config/hypr/hyprland.conf
        elif [ -f /mnt/etc/xdg/hypr/hyprland.conf ]; then
          cp /mnt/etc/xdg/hypr/hyprland.conf /mnt/etc/skel/.config/hypr/hyprland.conf
        fi
      "

      # 自動起動設定（nm-applet of 追加）
      run_cmd "Hyprland: nm-applet 自動起動設定" bash -c "
        echo 'exec-once = nm-applet --indicator' >> /mnt/etc/skel/.config/hypr/hyprland.conf
      "
      if [[ "${CONFIG[jp_ime]:-none}" =~ ^fcitx5 ]]; then
        run_cmd "Hyprland: fcitx5 自動起動設定" bash -c "
          echo 'exec-once = fcitx5 -d' >> /mnt/etc/skel/.config/hypr/hyprland.conf
        "
      fi
      ;;

    niri)
      local pkgs=(niri xwayland-satellite
                  waybar swaybg swaylock mako
                  foot wofi
                  xdg-desktop-portal-gnome
                  blueman
                  network-manager-applet
                  grim slurp wl-clipboard
                  brightnessctl
                  thunar
                  mousepad imv zathura zathura-pdf-mupdf mpv xarchiver)
      run_cmd "Niri インストール" \
        arch-chroot /mnt pacman -S --noconfirm "${pkgs[@]}" "${desktop_common_pkgs[@]}"

      # デフォルト設定ファイルのコピー（自動生成の不具合防止）
      run_cmd "Niri デフォルト設定コピー" bash -c "
        mkdir -p /mnt/etc/skel/.config/niri
        if [ -f /mnt/usr/share/doc/niri/default-config.kdl ]; then
          cp /mnt/usr/share/doc/niri/default-config.kdl /mnt/etc/skel/.config/niri/config.kdl
        elif [ -f /mnt/usr/share/doc/niri/config.kdl ]; then
          cp /mnt/usr/share/doc/niri/config.kdl /mnt/etc/skel/.config/niri/config.kdl
        fi
      "

      # 自動起動設定（nm-appletの追加）
      run_cmd "Niri: nm-applet 自動起動設定" bash -c "
        echo 'spawn-at-startup \"nm-applet\" \"--indicator\"' >> /mnt/etc/skel/.config/niri/config.kdl
      "
      if [[ "${CONFIG[jp_ime]:-none}" =~ ^fcitx5 ]]; then
        run_cmd "Niri: fcitx5 自動起動設定" bash -c "
          echo 'spawn-at-startup \"fcitx5\" \"-d\"' >> /mnt/etc/skel/.config/niri/config.kdl
        "
      fi
      print_ok "スクロール型タイリング: 横スクロールで無限ワークスペース"
      ;;
  esac

  # bluez がインストールされていれば bluetooth を有効化
  if arch-chroot /mnt pacman -Qi bluez &>/dev/null 2>&1; then
    # デフォルトの main.conf がない、または設定が空の場合の対処
    run_cmd "bluetooth デフォルト設定作成" bash -c "
      mkdir -p /mnt/etc/bluetooth
      if [ ! -f /mnt/etc/bluetooth/main.conf ]; then
        if [ -f /mnt/usr/share/doc/bluez/main.conf ]; then
          cp /mnt/usr/share/doc/bluez/main.conf /mnt/etc/bluetooth/main.conf
        else
          echo -e '[General]\nAutoEnable=true' > /mnt/etc/bluetooth/main.conf
        fi
      else
        # AutoEnable設定を有効化（なければ追記）
        if ! grep -q '^AutoEnable' /mnt/etc/bluetooth/main.conf; then
          sed -i '/^\[General\]/a AutoEnable=true' /mnt/etc/bluetooth/main.conf || \
            echo -e '[General]\nAutoEnable=true' >> /mnt/etc/bluetooth/main.conf
        fi
      fi
    "
    run_cmd "bluetooth 有効化" arch-chroot /mnt systemctl enable bluetooth
  fi

  # pipewire をグローバルユーザーサービスとして有効化（全 DE・全ユーザー共通）
  if arch-chroot /mnt pacman -Qi pipewire &>/dev/null 2>&1; then
    run_cmd "pipewire 自動起動設定" \
      arch-chroot /mnt systemctl --global enable pipewire pipewire-pulse
    print_ok "pipewire: 全ユーザーのログイン時に自動起動"
  fi
}

# ============================================
# 実行: ディスプレイマネージャー
# ============================================

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

      run_cmd "greetd 設定" bash -c "cat > /mnt/etc/greetd/config.toml << EOF
[terminal]
vt = 1

[default_session]
command = \"tuigreet --time --remember --cmd ${session_cmd}\"
user = \"greeter\"
EOF"
      run_cmd "greetd 有効化" arch-chroot /mnt systemctl enable greetd
      print_ok "greetd: セッションコマンド = ${session_cmd}"
      ;;
  esac
}

# ============================================
# 実行: GPU グラフィックドライバ
# ============================================

do_gpu_drivers() {
  print_step "GPU グラフィックドライバの検出と設定"

  local gpu_info
  gpu_info=$(lspci 2>/dev/null | grep -i -E 'vga|3d|display' || true)

  if echo "$gpu_info" | grep -qi 'nvidia'; then
    print_ok "NVIDIA GPU を検出しました。"
    
    # GPU 世代の判定 (GTX 16xx, RTX 20xx 以降は Turing 世代以降で nvidia-open が対応)
    # Pascal 以前 (GTX 10xx, GTX 9xx, GTX 7xx 等) はレガシーで nvidia-580xx-dkms 等が必要
    local model_info
    model_info=$(lspci -d 10de: 2>/dev/null || true)
    
    local legacy=no
    if echo "$model_info" | grep -qi -E 'GP10[0-9]|GM10[0-9]|GM20[0-9]|GK10[0-9]|GK20[0-9]|GF10[0-9]'; then
      legacy=yes
    elif echo "$model_info" | grep -qi -E 'GeForce (GTX 10|GTX 9|GTX 8|GTX 7|GTX 6|GT 10|GT 7|GTX Titan)'; then
      legacy=yes
    elif echo "$model_info" | grep -qi -E 'Quadro (P|M|K)'; then
      legacy=yes
    fi

    if [[ "$legacy" == "yes" ]]; then
      print_warn "検出された GPU は Pascal 以前のレガシー製品（GTX 10xx シリーズ等）です。"
      print_warn "公式リポジトリの最新ドライバ（590+）は非対応のため、nvidia-580xx-dkms が必要です。"
      
      local uname="${CONFIG[username]}"
      if [[ "${CONFIG[yay]:-no}" == "yes" && -n "$uname" ]]; then
        run_cmd "AUR から NVIDIA レガシー外部ドライバインストール (nvidia-580xx-dkms)" \
          arch-chroot /mnt sudo -u "$uname" yay -S --noconfirm nvidia-580xx-dkms nvidia-580xx-utils
      else
        print_err "一般ユーザーまたは AUR ヘルパー（yay）が未設定のため、AUR のレガシードライバをインストールできません。"
        print_warn "ドライバのインストールをスキップし、オープンソースの nouveau ドライバ（標準）で起動させます。"
        print_warn "再起動後に手動で AUR から nvidia-580xx-dkms をインストールしてください。"
      fi
    else
      run_cmd "NVIDIA オープンソースドライバインストール (nvidia-open-dkms)" \
        arch-chroot /mnt pacman -S --noconfirm nvidia-open-dkms linux-headers nvidia-utils
    fi

    # Wayland / KMS 向けの設定
    # /etc/mkinitcpio.conf の MODULES=(...) に nvidia 等を追加
    run_cmd "mkinitcpio KMS 設定" \
      arch-chroot /mnt sed -i -E 's/^MODULES=\((.*)\)/MODULES=(\1 nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
    run_cmd "initramfs 再生成" \
      arch-chroot /mnt mkinitcpio -P

    # カーネルパラメータに nvidia-drm.modeset=1 を追加
    # systemd-boot の場合
    if [[ "${CONFIG[bootloader]}" == "systemd-boot" ]]; then
      if [[ -f /mnt/boot/loader/entries/arch.conf ]]; then
        run_cmd "systemd-boot カーネルパラメータ追加" \
          sed -i 's/options \(.*\) rw quiet/options \1 rw quiet nvidia-drm.modeset=1/' /mnt/boot/loader/entries/arch.conf
      fi
      if [[ -f /mnt/boot/loader/entries/arch-fallback.conf ]]; then
        run_cmd "systemd-boot fallback カーネルパラメータ追加" \
          sed -i 's/options \(.*\) rw/options \1 rw nvidia-drm.modeset=1/' /mnt/boot/loader/entries/arch-fallback.conf
      fi
    # GRUB の場合
    elif [[ "${CONFIG[bootloader]}" == "grub" ]]; then
      if [[ -f /mnt/etc/default/grub ]]; then
        run_cmd "GRUB カーネルパラメータ追加" \
          sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 nvidia-drm.modeset=1"/' /mnt/etc/default/grub
        run_cmd "grub.cfg 再生成" \
          arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
      fi
    fi
  elif echo "$gpu_info" | grep -qi -E 'amd|ati'; then
    print_ok "AMD GPU を検出しました。Mesa ドライバーをインストールします。"
    run_cmd "AMD ドライバインストール" \
      arch-chroot /mnt pacman -S --noconfirm xf86-video-amdgpu vulkan-radeon
  elif echo "$gpu_info" | grep -qi 'intel'; then
    print_ok "Intel GPU を検出しました。Mesa ドライバーをインストールします。"
    run_cmd "Intel ドライバインストール" \
      arch-chroot /mnt pacman -S --noconfirm xf86-video-intel vulkan-intel
  else
    print_ok "標準グラフィック環境を適用します。"
    run_cmd "汎用 Mesa ドライバインストール" \
      arch-chroot /mnt pacman -S --noconfirm mesa
  fi
}

# ============================================
# 実行: AUR ヘルパー (yay)
# ============================================

do_aur_helper() {
  [[ "${CONFIG[yay]:-no}" != "yes" ]] && return
  [[ -z "${CONFIG[username]}" ]] && { print_warn "一般ユーザーが存在しないため、yay のインストールをスキップします。"; return; }

  print_step "AUR ヘルパー (yay-bin) のインストール"

  # ビルドに必要な git と base-devel を確認
  run_cmd "ビルド必須パッケージの確認・インストール" \
    arch-chroot /mnt pacman -S --noconfirm --needed git base-devel

  local uname="${CONFIG[username]}"
  
  # 代表ユーザーの権限で yay-bin をクローン＆ビルド
  run_cmd "yay-bin のビルドとインストール" \
    arch-chroot /mnt sudo -u "$uname" bash -c "
      cd /tmp && \
      rm -rf yay-bin && \
      git clone https://aur.archlinux.org/yay-bin.git && \
      cd yay-bin && \
      makepkg -si --noconfirm && \
      rm -rf /tmp/yay-bin
    "
}

# ============================================
# 実行: 後処理
# ============================================

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
  # ログファイルを安全なパーミッションで初期化
  touch /tmp/myarchinstall.log
  chmod 600 /tmp/myarchinstall.log
  echo "" > /tmp/myarchinstall.log
  print_ok "ログファイル: /tmp/myarchinstall.log"

  # ホスト環境のダウンロードを高速化
  _optimize_pacman_conf /etc/pacman.conf

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
  do_gpu_drivers
  do_display_manager
  do_cleanup

  # セキュリティのため、メモリ上のパスワード情報をクリア
  CONFIG[root_password]=""
  CONFIG[user_password]=""
  CONFIG[users]=""

  echo ""
  echo -e "${GREEN}${BOLD}"
  echo "╔══════════════════════════════════════════╗"
  echo "║   インストール完了！再起動してください   ║"
  echo "╚══════════════════════════════════════════╝"
  echo -e "${RESET}"
  echo -e "  再起動コマンド: ${BOLD}reboot${RESET}"

  # DMなしでデスクトップ環境を入れた場合、またはCLI環境でのログイン・WiFi案内
  echo -e "\n  ${BOLD}── 再起動後のヒント ──${RESET}"
  if [[ "${CONFIG[desktop]}" != "none" && "${CONFIG[dm]}" == "none" ]]; then
    echo -e "  • デスクトップ環境の起動:"
    echo -e "    ログイン後、以下のコマンドでデスクトップを起動できます："
    case "${CONFIG[desktop]}" in
      sway)     echo -e "      ${BOLD}sway${RESET}" ;;
      hyprland) echo -e "      ${BOLD}Hyprland${RESET}" ;;
      niri)     echo -e "      ${BOLD}niri-session${RESET}" ;;
      gnome)    echo -e "      ${BOLD}gnome-session --wayland${RESET} (Wayland) または ${BOLD}startx${RESET} (X11)" ;;
      kde)      echo -e "      ${BOLD}startplasma-wayland${RESET} (Wayland) または ${BOLD}startx${RESET} (X11)" ;;
      *)        echo -e "      ${BOLD}startx${RESET}" ;;
    esac
  fi
  # WiFiを利用する場合のCUI接続案内
  if [[ "${CONFIG[wifi_backend]}" != "none" ]]; then
    echo -e "  • 再起動後のCUIでのWiFi接続:"
    echo -e "    ログイン後、以下のインタラクティブツールでWiFiに接続できます："
    echo -e "      ${BOLD}sudo nmtui${RESET}"
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
  # エラー発生時のトラブルシューティング案内を設定
  trap 'error_handler ${LINENO} "$BASH_COMMAND" $?' ERR

  # root チェック
  if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}エラー: このスクリプトは root で実行してください。${RESET}"
    echo "  例: sudo bash install.sh"
    exit 1
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

  while true; do
    show_summary

    echo ""
    local menu_choice
    menu_choice=$(select_from_list "実行するアクションを選択してください:" \
      "設定を修正: 1. ディスク選択" \
      "設定を修正: 2. パーティション構成" \
      "設定を修正: 3. システム設定（ロケール・IME等）" \
      "設定を修正: 4. ユーザー設定" \
      "設定を修正: 5. ブートローダー" \
      "設定を修正: 6. デスクトップ環境" \
      "設定を修正: 7. ネットワーク設定（WiFi等）" \
      "設定を修正: 8. ミラーサーバー設定" \
      "設定を修正: 9. フォント設定" \
      "設定を修正: 10. 追加パッケージ設定" \
      "インストールを実行する" \
      "インストールを中止して終了する")

    case "$menu_choice" in
      *1.\ ディスク選択*)
        step_disk
        ;;
      *2.\ パーティション構成*)
        step_partition_scheme
        ;;
      *3.\ システム設定*)
        step_system
        ;;
      *4.\ ユーザー設定*)
        step_users
        ;;
      *5.\ ブートローダー*)
        step_bootloader
        ;;
      *6.\ デスクトップ環境*)
        step_desktop
        ;;
      *7.\ ネットワーク設定*)
        step_network
        ;;
      *8.\ ミラーサーバー設定*)
        step_mirror
        ;;
      *9.\ フォント設定*)
        step_fonts
        ;;
      *10.\ 追加パッケージ設定*)
        step_extra_packages
        ;;
      "インストールを実行する")
        if confirm "本当にインストールを開始しますか？（ディスクデータが消去されます）"; then
          run_install
          break
        fi
        ;;
      "インストールを中止して終了する"|__BACK__|__EXIT__)
        echo -e "\n  インストールを中断しました。"
        exit 0
        ;;
    esac
  done
}

main "$@"
