#!/usr/bin/env bash
# ============================================
#  ドライランの通しテスト
# ============================================
# install.sh --dry-run を最初から最後まで、回答を自動入力して実行する。
# パッケージ導入やディスク操作に関わるコマンドは何もしない偽物に差し替えるので、
# Arch Linux 以外（GitHub Actions の Ubuntu など）でも動かせる。
#
# 確認すること:
#   - 対話の流れが最後まで進み「インストール完了」まで到達する
#   - 予期しないエラー（ERR トラップ）が一度も出ない
#   - 予約されたユーザー名・存在しないパッケージ名を入力時に弾く
#   - 確認画面・修正メニューが表示される
#
# 使い方: sudo bash tests/dryrun.sh [インストール先ディスクの番号（既定 1）]
#   root が必要（install.sh 自体が root を要求するため）。ドライランなので
#   ディスクには一切書き込まない。候補にディスクが無い環境では、
#   ESCA_TEST_ALLOW_LOOP=1 と loop デバイスを用意すれば候補に出せる。

set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISK_NO="${1:-1}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ "$EUID" -ne 0 ]]; then
  echo "root で実行してください: sudo bash tests/dryrun.sh" >&2
  exit 1
fi

# --- 偽物のコマンド ---
mkdir -p "$WORK/stub"
for c in sgdisk mkfs.fat mkfs.ext4 reflector arch-chroot genfstab pacstrap partprobe ping; do
  printf '#!/bin/sh\nexit 0\n' > "$WORK/stub/$c"
done
printf '#!/bin/sh\necho "System clock synchronized: yes"\n' > "$WORK/stub/timedatectl"
# pacman: 名前確認（-Si / -Sg）では nosuchpkg だけ「見つからない」と答える
cat > "$WORK/stub/pacman" << 'EOF'
#!/bin/sh
case "$*" in
  *-Si*|*-Sg*) case "$*" in *nosuchpkg*) exit 1 ;; esac ;;
esac
exit 0
EOF
printf '#!/bin/sh\necho "00:02.0 VGA compatible controller [0300]: Intel Corporation HD Graphics 620 [8086:5916]"\n' > "$WORK/stub/lspci"
printf '#!/bin/sh\necho none\nexit 1\n' > "$WORK/stub/systemd-detect-virt"
chmod +x "$WORK/stub/"*

# 追加パッケージ名の確認は同期データベースがあるときだけ行われるため、無ければ仮に置く
created_db=""
if [[ ! -f /var/lib/pacman/sync/core.db ]]; then
  mkdir -p /var/lib/pacman/sync
  touch /var/lib/pacman/sync/core.db
  created_db="yes"
fi
cleanup_db() { [[ -n "$created_db" ]] && rm -f /var/lib/pacman/sync/core.db; rm -rf "$WORK"; }
trap cleanup_db EXIT

# --- 回答 ---
# UEFI 環境ではブートローダーの選択が1問増える
uefi_answer=()
[[ -d /sys/firmware/efi/efivars ]] && uefi_answer=(1)
answers=(
  y                       # 開始しますか
  "$DISK_NO" y            # ディスク選択・確認
  1 1                     # パーティション構成・ext4
  ""                      # ホスト名（既定 esca）
  n                       # Windows 共存
  password1 password1     # root パスワード
  y                       # 一般ユーザーを作成
  root                    # 予約名 → 弾かれるはず
  sk password1 password1  # ユーザー名・パスワード
  y 1 1                   # sudo・通常 sudo・bash
  n                       # さらに追加しない
  "${uefi_answer[@]}"     # ブートローダー（UEFI のみ）
  6 2                     # COSMIC・SDDM
  3                       # 設定の引き継ぎ: 最後の選択肢（引き継がない）
  1                       # Wi-Fi: iwd
  "" "" "" ""             # SSH・LibreOffice・Chrome・yt-fzf（既定 Yes）
  n                       # ufw
  "htop nosuchpkg"        # 存在しないパッケージ → 弾かれるはず
  htop                    # 追加パッケージ
  2 10                    # 確認画面 → 修正 → 戻る
  1                       # インストールを実行
  YES                     # 最終確認
)
# 「設定の引き継ぎ」はホストに ~/.config があるかで選択肢の数が変わる。
# 最後の選択肢（引き継がない）を選ぶため、ホスト設定が無ければ 2 にする。
if ! compgen -G "/home/*/.config" > /dev/null && [[ ! -d "${ROOT_DIR}/dotfiles/.config" ]]; then
  for i in "${!answers[@]}"; do
    if [[ "${answers[$i]}" == "3" && "${answers[$((i-1))]}" == "2" && "${answers[$((i-2))]}" == "6" ]]; then
      answers[i]=2
    fi
  done
fi
printf '%s\n' "${answers[@]}" > "$WORK/answers.txt"

# パスワード入力（read -s）は端末設定を切り替えるため、少し間を空けて1行ずつ送る
feed() { while IFS= read -r l; do sleep 0.5; printf '%s\r' "$l"; done < "$WORK/answers.txt"; sleep 10; }

echo "ドライランを実行しています（1分ほどかかります）..."
feed | PATH="$WORK/stub:$PATH" TERM=xterm-256color ESCA_TEST_ALLOW_LOOP="${ESCA_TEST_ALLOW_LOOP:-0}" \
  timeout 180 script -qfec "bash '${ROOT_DIR}/install.sh' --dry-run" /dev/null > "$WORK/raw.log" 2>&1 || true
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$WORK/raw.log" | tr -d '\r' > "$WORK/out.log"

fail=0
expect() { if grep -qF -- "$2" "$WORK/out.log"; then echo "  OK   $1"; else echo "  NG   $1"; fail=1; fi; }
reject() { if grep -qF -- "$2" "$WORK/out.log"; then echo "  NG   $1"; fail=1; else echo "  OK   $1"; fi; }
expect "予約されたユーザー名を弾く"         "「root」はシステムが使う名前のため使用できません"
expect "存在しないパッケージ名を弾く"       "公式リポジトリに見つかりません: nosuchpkg"
expect "確認画面が出る"                     "インストール内容の確認"
expect "修正メニューが出る"                 "修正する項目を選択してください"
expect "最後まで完了する"                   "インストール完了"
reject "予期しないエラーが出ない"           "予期しないエラーで停止しました"

if [[ "$fail" -ne 0 ]]; then
  echo ""
  echo "---- 出力の末尾 ----"
  tail -40 "$WORK/out.log"
  exit 1
fi
echo "結果: すべて成功"
