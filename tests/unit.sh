#!/usr/bin/env bash
# ============================================
#  install.sh の単体テスト
# ============================================
# install.sh の関数だけを読み込み（main は実行されない）、
# 過去に不具合が出た箇所を中心に、入力と結果の組み合わせを確かめる。
# root 権限・ネットワーク・Arch Linux は不要。
#
# 使い方: bash tests/unit.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  OK   %s\n' "$1"; }
ng()   { FAIL=$((FAIL + 1)); printf '  NG   %s\n' "$1"; [[ -n "${2:-}" ]] && printf '       %s\n' "$2"; return 0; }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else ng "$1" "期待: [$3] / 実際: [$2]"; fi; }
section() { printf '\n== %s\n' "$1"; }

# 関数を読み込む（install.sh の set -euo pipefail はテスト側では外す）
# shellcheck source=../install.sh
source "${ROOT_DIR}/install.sh"
set +euo pipefail
CONFIG[log_file]="$(mktemp)"

# --------------------------------------------
section "GPU 判定 (_detect_gpu)"
# 「compatible」「Communication」に含まれる "ati" で AMD と誤判定していた不具合の回帰テスト
intel='00:02.0 VGA compatible controller [0300]: Intel Corporation HD Graphics 620 [8086:5916] (rev 02)'
amd='06:00.0 VGA compatible controller [0300]: Advanced Micro Devices, Inc. [AMD/ATI] Navi 23 [Radeon RX 6600] [1002:73ff]'
rtx='01:00.0 3D controller [0302]: NVIDIA Corporation TU117M [GeForce GTX 1650 Mobile] [10de:1f91] (rev a1)'
gtx1060='01:00.0 VGA compatible controller [0300]: NVIDIA Corporation GP106 [GeForce GTX 1060 6GB] [10de:1c03] (rev a1)'
virtio='00:01.0 VGA compatible controller [0300]: Red Hat, Inc. Virtio 1.0 GPU [1af4:1050] (rev 01)'
eq "Intel 内蔵 GPU は intel"                 "$(_detect_gpu "$intel" none)" "intel|Intel"
eq "AMD は amdgpu"                          "$(_detect_gpu "$amd" none)" "amdgpu|AMD"
eq "Intel + RTX のハイブリッドは nvidia"     "$(_detect_gpu "$intel"$'\n'"$rtx" none)" "nvidia|NVIDIA"
eq "GTX 1060（Pascal）は nouveau"           "$(_detect_gpu "$gtx1060" none)" "nouveau|NVIDIA（Pascal 以前の世代）"
eq "QEMU/KVM は virtual"                    "$(_detect_gpu "$virtio" kvm)" "virtual|仮想環境 (kvm)"
eq "仮想環境は GPU 名より優先"               "$(_detect_gpu "$intel" oracle)" "virtual|仮想環境 (oracle)"
eq "判定できない GPU は空"                   "$(_detect_gpu '00:01.0 VGA compatible controller [0300]: Matrox G200eR2 [102b:0534]' none)" "|"
eq "表示デバイスが無ければ空"                "$(_detect_gpu '' none)" "|"

# --------------------------------------------
section "パーティション名 (part_suffix)"
eq "SATA: sda → sda1"           "$(part_suffix /dev/sda 1)" "/dev/sda1"
eq "NVMe: nvme0n1 → nvme0n1p2"  "$(part_suffix /dev/nvme0n1 2)" "/dev/nvme0n1p2"
eq "eMMC: mmcblk0 → mmcblk0p1"  "$(part_suffix mmcblk0 1)" "/dev/mmcblk0p1"

# --------------------------------------------
section "ユーザー名の予約語 (_is_reserved_username)"
for u in root bin wheel audio sddm greeter systemd-network; do
  if _is_reserved_username "$u"; then ok "「$u」は使えない"; else ng "「$u」は使えない"; fi
done
for u in sk taro yamada2; do
  if _is_reserved_username "$u"; then ng "「$u」は使える"; else ok "「$u」は使える"; fi
done

# --------------------------------------------
section "表示幅 (_dispw)"
for loc in C C.UTF-8; do
  eq "半角のみ ($loc)"     "$(LC_ALL=$loc _dispw 'abc')" "3"
  eq "全角のみ ($loc)"     "$(LC_ALL=$loc _dispw 'ディスク')" "8"
  eq "全角と半角 ($loc)"   "$(LC_ALL=$loc _dispw 'GPU ドライバ')" "12"
done

# --------------------------------------------
section "日本語表示ラベル (_label)"
# 選択肢として出しうる値が、内部コードのまま画面に出ないこと
for pair in partition_scheme:auto_noswap partition_scheme:auto_swap partition_scheme:manual \
            boot_mode:uefi boot_mode:bios \
            desktop:none desktop:kde desktop:gnome desktop:xfce desktop:budgie desktop:cosmic desktop:hyprland desktop:niri \
            dm:sddm dm:gdm dm:lightdm dm:cosmic-greeter dm:greetd dm:none \
            gpu_driver:nvidia gpu_driver:nouveau gpu_driver:amdgpu gpu_driver:intel gpu_driver:virtual gpu_driver:none \
            wifi_backend:none config_source:host config_source:git config_source:none \
            kde_apps:minimal kde_apps:standard kde_apps:full; do
  kind="${pair%%:*}"; val="${pair#*:}"
  label="$(_label "$kind" "$val")"
  # 大文字小文字だけの違い（cosmic → COSMIC 等）は表示名として正しいので許容する
  if [[ -n "$label" && "$label" != "$val" ]]; then ok "$kind=$val → $label"; else ng "$kind=$val が日本語表示になっていない" "$label"; fi
done

# --------------------------------------------
section "initramfs のドロップイン (_initramfs_dropin_body)"
eq "追加設定が無い構成ではドロップインを作らない" "$(_initramfs_dropin_body ext4 intel '')" ""

body="$(_initramfs_dropin_body btrfs nvidia /dev/sda2)"
apply() { # $1: 既定の HOOKS
  bash -c 'set -eu; MODULES=(); HOOKS=('"$1"'); eval "$2"; echo "MODULES=${MODULES[*]}|HOOKS=${HOOKS[*]}"' _ "$1" "$body"
}
udev_hooks='base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck'
sd_hooks='base systemd autodetect microcode modconf kms keyboard sd-vconsole block filesystems fsck'
eq "従来型 initramfs: btrfs/NVIDIA を追加・kms を除去・resume を追加" "$(apply "$udev_hooks")" \
  "MODULES=btrfs nvidia nvidia_modeset nvidia_uvm nvidia_drm|HOOKS=base udev autodetect microcode modconf keyboard keymap consolefont block resume filesystems fsck"
eq "systemd 型 initramfs: resume は追加しない" "$(apply "$sd_hooks")" \
  "MODULES=btrfs nvidia nvidia_modeset nvidia_uvm nvidia_drm|HOOKS=base systemd autodetect microcode modconf keyboard sd-vconsole block filesystems fsck"
body="$(_initramfs_dropin_body ext4 intel /dev/sda2)"
eq "resume は二重に追加しない" "$(apply "${udev_hooks/filesystems/resume filesystems}")" \
  "MODULES=|HOOKS=base udev autodetect microcode modconf kms keyboard keymap consolefont block resume filesystems fsck"

# --------------------------------------------
section "確認画面 (show_summary)"
CONFIG[disk]=/dev/nvme0n1; CONFIG[partition_scheme]=auto_noswap; CONFIG[hostname]=esca
CONFIG[boot_mode]=uefi; CONFIG[desktop]=cosmic; CONFIG[dm]=sddm; CONFIG[gpu_driver]=intel
CONFIG[wifi_backend]=iwd; CONFIG[users_count]=2
CONFIG[users]="sk|x|yes|bash|wheel
taro|y|no|zsh|wheel"
CONFIG[extra_pkgs]="htop btop"
clear() { :; }
summary="$(show_summary 2>&1 | sed 's/\x1b\[[0-9;]*[mK]//g')"
lines=$(printf '%s\n' "$summary" | wc -l)
maxw=0
# 区切り線（━ ─）は端末では半角幅だが _dispw は全角扱いするため除外する
while IFS= read -r l; do
  [[ "$l" =~ ^[[:space:]]*(━|─)+$ ]] && continue
  w=$(_dispw "$l"); (( w > maxw )) && maxw=$w
done <<< "$summary"
if (( lines <= 30 )); then ok "30行以内に収まる（${lines}行）"; else ng "30行以内に収まる" "${lines}行"; fi
if (( maxw <= 80 )); then ok "80桁以内に収まる（最大${maxw}桁）"; else ng "80桁以内に収まる" "最大${maxw}桁"; fi
if grep -q 'auto_noswap\|uefi' <<< "$summary"; then ng "内部値（auto_noswap 等）が出ていない"; else ok "内部値（auto_noswap 等）が出ていない"; fi
last_info=$(grep -n 'ディスク' <<< "$summary" | tail -n1 | cut -d: -f1)
if (( lines - last_info <= 6 )); then ok "消去されるディスクが画面の下の方にある"; else ng "消去されるディスクが画面の下の方にある" "${last_info}行目 / ${lines}行"; fi

# --------------------------------------------
section "標準コンソール用の記号 (TERM=linux)"
eq "TERM=linux では [OK]"       "$(TERM=linux bash -c "source '${ROOT_DIR}/install.sh'; echo \"\$ICON_OK\$ICON_WARN\$ICON_ERR\"")" "[OK][!!][NG]"
eq "それ以外の端末では記号"       "$(TERM=xterm-256color bash -c "source '${ROOT_DIR}/install.sh'; echo \"\$ICON_OK\$ICON_WARN\$ICON_ERR\"")" "✔⚠✘"

# --------------------------------------------
section "その他"
eq "_join: 区切りでつなぐ"      "$(_join '、' Chrome yay OpenSSH)" "Chrome、yay、OpenSSH"
eq "_join: 空なら「なし」"      "$(_join '、')" "なし"
INSTALL_START=""; NOTICES=()
print_warn "開始前の警告" > /dev/null
INSTALL_START=1
print_warn "後で必要な案内" > /dev/null
print_warn "ドライランのためスキップ" > /dev/null
eq "完了画面用の注意事項は開始後・ドライラン以外だけ集める" "${#NOTICES[@]}:${NOTICES[0]:-}" "1:後で必要な案内"

rm -f "${CONFIG[log_file]}"
printf '\n結果: 成功 %d 件 / 失敗 %d 件\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
