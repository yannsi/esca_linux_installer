#!/usr/bin/env bash
# ============================================
#  Esca Linux インストーラー — Arch Linux ベース・日本語環境セットアップ
# ============================================

set -euo pipefail
# -E (errtrace): ERR トラップを関数・サブシェルにも継承させる。
# これが無いと関数内で失敗したときにトラップが呼ばれず、原因不明のまま終了する。
set -E

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

LOG_FILE="/tmp/esca-install-$(date +%Y%m%d-%H%M%S).log"

# --- /etc/skel の書き込み先 ---
# 【重要】ドライランでも設定生成の処理そのものは走る。パスを直書きしていると
# インストール先が未マウントの状態で Live 環境の ${SKEL_ROOT} に実ファイルを
# 作ってしまい、「変更は適用されません」という説明と食い違う。
# ドライラン時だけ書き込み先を一時ディレクトリへ逃がす。
# 生成物はそのまま残るので、何が書かれる予定かを実際に確認できる。
if [[ "$DRY_RUN" == "yes" ]]; then
  SKEL_ROOT="$(mktemp -d /tmp/esca-dryrun-skel-XXXXXX)"
else
  SKEL_ROOT="/mnt/etc/skel"
fi

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
  # 実際に使用する root / swap パーティション。do_format_and_mount で確定し、
  # do_chroot_config（resume フック判定）と do_bootloader（resume= 付与）で共用する。
  # swap_part が空文字なら「swap なし」を意味する。
  [root_part]=""
  [swap_part]=""
  [fs_type]="ext4"
  [desktop]="none"
  [kde_apps]="none"
  [dm]="none"
  # 設定の引き継ぎ元: host / git / none （step_config_source で選択）
  # 既定は host（ホストPC → GitHub → 無し の順に探す）
  [config_source]="host"
  [root_password]=""
  [users]=""
  [users_count]="0"
  [japanese_env]="yes"
  [jp_ime]="fcitx5-mozc"
  [wifi_backend]="none"
  [use_resolved]="no"
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
  [install_office]="yes"
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

# このスクリプト自身が置かれているディレクトリ。
# ISO 同梱の dotfiles/ を探すのに使う。シンボリックリンク経由の起動でも実体を指すよう
# cd + pwd で解決する（dirname だけだと相対パスのまま返ることがある）。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 設定の複製元となる「ホーム相当のディレクトリ」を返す。
#
# 【重要】Live ISO には /home にユーザーが存在しない。ホストPCの設定を既定に
# したくても、実ユーザーのホームを探す方法だけでは ISO から起動した瞬間に
# 何も見つからず、機能全体が無言でスキップされる。
# そこでインストーラと同じ場所に置いた dotfiles/ を最優先で見る。
# これなら設定を同梱したカスタム ISO を作るだけで複製が効く。
#
# 探索順:
#   1. 環境変数 ESCA_DOTFILES（明示指定。検証やCI用）
#   2. <スクリプトと同じ場所>/dotfiles          ← ISO 同梱用
#   3. sudo 実行元のホーム（SUDO_USER）
#   4. /home 直下の最初の実ユーザー
#   5. GitHub の dotfiles リポジトリを取得（最終手段。要ネットワーク）
#
# 【重要】3・4 は ".config を持っていること" を条件にする。
# Live ISO の /home は空か、あっても .config を持たない骨だけのことがある。
# 存在チェックだけで採用すると、中身が無いディレクトリを掴んだまま 5 に
# 到達できず、取得できるはずの設定が何も複製されない状態になる。
#
# 5 はネットワークに依存するため、この関数が空文字を返すことはありうる。
# 呼び出し側は「空文字 or 存在しないパス」を必ず安全に扱うこと。
#
# 【重要】ここで ~/dotfiles を優先してはいけない。
# dotfiles を git 管理して ~/.config/<app> からリンクを張る運用（同梱 setup.sh の方式）
# でも、リポジトリに入っているのは一部の設定だけで、rofi・fcitx5・mozc などは
# ホーム本体にしか無いのが普通。リポジトリ側を優先すると、そこに無い設定が
# 丸ごと複製対象から外れる（電源メニューのテーマが消える等）。
# ホーム本体を見れば「リンク済みのもの＝リポジトリの実体」も「リンクしていないもの」も
# 両方拾える。リンクの実体化は複製側の cp -aL が担当する。
#
# 返すのは「.config を含むディレクトリ」であること。呼び出し側は
# "$(_host_home)/.config/..." の形で参照する。
_host_home() {
  # ── 設定ソースの選択（step_config_source で設定）──
  # 【重要】ここ一箇所で分岐させることで、_host_home を参照している全ての
  # 呼び出し元（Waybar / Hyprland / Niri / 各種アプリ設定）に一括で効く。
  # 呼び出し元はいずれも「空文字 or 存在しないパス」を安全に扱えるようになっている。
  #   host : ホストPC → GitHub → 無し（既定）
  #   git  : ホストPCを見ず、GitHub の dotfiles リポジトリを取得して使う
  #   none : 何も引き継がず、各パッケージの既定設定のみ使う
  local src="${CONFIG[config_source]:-host}"
  case "$src" in
    none)
      echo ""
      return
      ;;
    git)
      _git_dotfiles
      return
      ;;
  esac

  local found
  found=$(_host_home_raw)
  if [[ -n "$found" ]]; then
    echo "$found"
    return
  fi
  # ホスト側に設定が無い（＝素の Live ISO から起動した）場合は GitHub から取得する。
  # 取得にも失敗すれば空文字が返り、各パッケージの既定設定のみになる。
  _git_dotfiles
}

# ホストPC側の設定ディレクトリだけを探す（GitHub取得へのフォールバックはしない）。
# 見つからなければ空文字を返す。
# 【重要】CONFIG[config_source] を一切参照しないこと。
# step_config_source が「そもそもホスト設定が存在するか」を判定するために
# この関数を使うため、ここで分岐させると選択肢の提示が壊れる。
_host_home_raw() {
  if [[ -n "${ESCA_DOTFILES:-}" && -d "${ESCA_DOTFILES}/.config" ]]; then
    echo "${ESCA_DOTFILES}"
    return
  fi
  if [[ -d "${SCRIPT_DIR}/dotfiles/.config" ]]; then
    echo "${SCRIPT_DIR}/dotfiles"
    return
  fi
  if [[ -n "${SUDO_USER:-}" && -d "/home/${SUDO_USER}/.config" ]]; then
    echo "/home/${SUDO_USER}"
    return
  fi
  local d
  for d in /home/*; do
    [[ -d "$d/.config" ]] || continue
    echo "$d"
    return
  done
  echo ""
}

# GitHub 上の dotfiles リポジトリを取得し、そのディレクトリのパスを返す
# （失敗時は空文字）。
#
# 【重要】mktemp -d を使わず固定パスにすること。
# _host_home() は "$(_host_home)" の形でサブシェルから何度も呼ばれるため、
# 取得先をグローバル変数にキャッシュしても呼び出し元には伝わらない。
# mktemp だと呼ばれるたびに clone し直すことになる。
# 固定パスなら 2回目以降は取得済みのものをそのまま再利用できる。
#
# 【重要】この関数は「パス」を標準出力で返す契約になっている。
# git / curl の進捗表示が stdout に混ざるとパスが壊れるため、
# 取得コマンドの出力は必ず捨てること。
ESCA_DOTFILES_REPO="${ESCA_DOTFILES_REPO:-https://github.com/yannsi/esca-dotfiles}"
ESCA_DOTFILES_BRANCH="${ESCA_DOTFILES_BRANCH:-main}"

_git_dotfiles() {
  local d="/tmp/esca-git-dotfiles"

  # 取得済みならそのまま使う
  if [[ -d "$d/.config" && ! -L "$d" ]]; then
    echo "$d"
    return
  fi

  # 前回の中断で壊れた残骸やシンボリックリンクが居座っている場合に備えて作り直す
  [[ -L "$d" ]] && rm -f "$d"
  rm -rf "$d"

  # 1) git があれば git clone（--depth=1 で履歴は取らない）
  if command -v git > /dev/null 2>&1; then
    if git clone --depth=1 --branch "$ESCA_DOTFILES_BRANCH" \
         "$ESCA_DOTFILES_REPO" "$d" > /dev/null 2>&1; then
      # .git は不要（そのままだと各ユーザーのホームに .git が配られてしまう）
      rm -rf "$d/.git"
      [[ -d "$d/.config" ]] && { echo "$d"; return; }
    fi
    rm -rf "$d"
  fi

  # 2) git が無い / clone に失敗した場合は tarball を取得する。
  # Live ISO に git が入っていない構成でも curl はほぼ確実にあるため、
  # ここまで用意しておくと「ネットワークはあるのに取得できない」を減らせる。
  if command -v curl > /dev/null 2>&1; then
    local tarball="/tmp/esca-git-dotfiles.tar.gz"
    local tmpx="/tmp/esca-git-dotfiles-x"
    rm -rf "$tmpx" "$tarball"
    if curl -fsSL "${ESCA_DOTFILES_REPO}/archive/refs/heads/${ESCA_DOTFILES_BRANCH}.tar.gz" \
         -o "$tarball" > /dev/null 2>&1; then
      mkdir -p "$tmpx" 2>/dev/null || { echo ""; return; }
      if tar xzf "$tarball" -C "$tmpx" > /dev/null 2>&1; then
        # tarball は "<repo>-<branch>/" という1階層でくるまれている
        local inner
        inner=$(find "$tmpx" -mindepth 1 -maxdepth 1 -type d | head -n1)
        if [[ -n "$inner" && -d "$inner/.config" ]]; then
          mv "$inner" "$d" 2>/dev/null && {
            rm -rf "$tmpx" "$tarball"
            echo "$d"
            return
          }
        fi
      fi
    fi
    rm -rf "$tmpx" "$tarball"
  fi

  rm -rf "$d"
  echo ""
}

# ============================================
# 壁紙
# ============================================
# Esca の壁紙をターゲットへ配置し、その「インストール先の絶対パス」を返す
# （配置できなければ空文字）。返すのは /mnt を含まないターゲット視点のパス。
#
# 【重要】この関数は「パス」を標準出力で返す契約。
# 進捗表示やエラーを stdout に混ぜないこと。
#
# 探索順:
#   1. 引き継ぎ元 dotfiles の esca / esca.png（GitHub 取得やホストPCから来たもの）
#   2. GitHub から直接ダウンロード（1 が無い＝引き継ぎ「なし」を選んだ場合など）
WALLPAPER_DEST="/usr/share/backgrounds/esca/esca.png"

# GitHub から取得したバイナリを /tmp にキャッシュしつつ、そのパスを返す
# （取得できなければ空文字）。
#
# 【重要】キャッシュの存在確認だけで再利用しないこと。
# 前回の実行が転送中に中断されると、0 バイトや途中までのファイルが残る。
# それをそのまま配置すると「壁紙が真っ黒」「グリフが豆腐のまま」という、
# 原因の分かりにくい形で失敗する。中身を検証し、壊れていれば取り直す。
#
# 引数1: キャッシュ先のパス / 引数2: 取得元 URL
# 引数3: 期待する先頭バイト列（省略可） / 引数4: 期待する末尾付近のバイト列（省略可）
_fetch_cached() {
  local tmp="$1" url="$2" magic="${3:-}" trailer="${4:-}"

  _valid() {
    [[ -s "$1" ]] || return 1
    if [[ -n "$magic" ]]; then
      # 【重要】マジックバイトが指定されている場合はサイズで足切りしないこと。
      # かつて同梱していた EscaSymbols.otf はグリフ1個だけの約 1.2KB しかなく、
      # 「1KB 未満は不正」のような閾値を入れると正当なフォントを弾いた。
      # （このフォント自体は廃止したが、小さい正当ファイルは今後もありうる）
      [[ "$(head -c "${#magic}" "$1" 2>/dev/null)" == "$magic" ]] || return 1
    elif [[ "$(stat -c %s "$1" 2>/dev/null || echo 0)" -lt 512 ]]; then
      # 形式を確認できない場合のみ、HTML のエラーページ等を弾く目的で
      # 最低限のサイズを見る
      return 1
    fi
    # 【重要】先頭だけ見ても「転送が途中で切れたファイル」は検出できない。
    # 元々防ぎたいのは中断されたダウンロードの再利用なので、
    # 終端マーカーを持つ形式では末尾も必ず確認する。
    if [[ -n "$trailer" ]]; then
      tail -c 16 "$1" 2>/dev/null | grep -qF -- "$trailer" || return 1
    fi
    return 0
  }

  if [[ -f "$tmp" ]] && _valid "$tmp"; then
    unset -f _valid
    echo "$tmp"
    return
  fi
  rm -f "$tmp"

  command -v curl > /dev/null 2>&1 || { unset -f _valid; echo ""; return; }
  if curl -fsSL "$url" -o "$tmp" > /dev/null 2>&1 && _valid "$tmp"; then
    unset -f _valid
    echo "$tmp"
    return
  fi
  rm -f "$tmp"
  unset -f _valid
  echo ""
}

_install_wallpaper() {
  local src="" home_dir
  home_dir=$(_host_home)

  if [[ -n "$home_dir" ]]; then
    local c
    for c in "esca" "esca.png" "wallpapers/esca.png" ".config/backgrounds/esca.png"; do
      if [[ -f "${home_dir}/${c}" ]]; then
        src="${home_dir}/${c}"
        break
      fi
    done
  fi

  # dotfiles 側に無ければ GitHub から直接取得する。
  # 「引き継ぎなし」を選んでも Esca らしい見た目にはしたいので、
  # 壁紙だけは別途取りに行く。
  if [[ -z "$src" ]]; then
    # 先頭は PNG のマジックバイト（\x89PNG）、末尾は終端チャンク IEND を確認する。
    # 壁紙は 1MB 超あるので、転送が途中で切れたファイルが残りやすい。
    src=$(_fetch_cached "/tmp/esca-wallpaper.png" \
      "https://raw.githubusercontent.com/${ESCA_DOTFILES_REPO#https://github.com/}/${ESCA_DOTFILES_BRANCH}/esca" \
      "$(printf '\x89PNG')" "IEND")
  fi

  [[ -z "$src" ]] && { echo ""; return; }

  # 【重要】ここは run_cmd を通さず直接 /mnt に書くため、ドライラン判定を
  # 自前で持つ必要がある。未マウントの状態で書くと Live ISO 側のルートに
  # 実ファイルができてしまい、「変更は適用されません」という説明と食い違う。
  # ただしパスは返す。呼び出し元はこの値を設定ファイルに埋め込むので、
  # 空文字を返すとドライランでの生成物が本番と別物になってしまう。
  if [[ "${CONFIG[dry_run]}" == "yes" ]]; then
    echo "$WALLPAPER_DEST"
    return
  fi

  # 拡張子なしの "esca" で配布されているが、配置先では .png に統一する
  # （swaybg / hyprpaper は内容で判別するので拡張子自体は必須ではない）。
  mkdir -p "/mnt$(dirname "$WALLPAPER_DEST")" 2>/dev/null || { echo ""; return; }
  if cp "$src" "/mnt${WALLPAPER_DEST}" 2>/dev/null; then
    chmod 644 "/mnt${WALLPAPER_DEST}" 2>/dev/null || true
    echo "$WALLPAPER_DEST"
  else
    echo ""
  fi
}

# 引き継いだ starship 設定から Esca 専用グリフを取り除く。
#
# 【経緯】以前は独自フォント EscaSymbols.otf を U+100000 に配置し、
# fontconfig のフォールバックで拾わせていた。しかし実機の GNOME では
# どうしても豆腐(□)のままで表示できなかった。
# fontconfig の match 対象を monospace 限定から全パターンに広げても解決せず、
# 私用領域(PUA)の符号位置はレンダラ側がフォールバックを拒否することがあり
# （PUA は意味が未定義なため、システムフォールバックを行わない実装がある）、
# 環境ごとの当たり外れを完全には制御できない。
#
# 【判断】「特定環境で豆腐になる独自グリフ」より
# 「どこでも確実に出る標準の記号」を優先する。ブランディングのために
# 利用者のプロンプトが壊れるのは本末転倒なので、独自フォントは廃止した。
#
# dotfiles 側の starship.toml には U+100000 が直接書き込まれているため、
# 引き継いだ場合はここで Nerd Fonts の Linux アイコン (U+F17C) に置換する。
_strip_esca_glyph() {
  local f="${SKEL_ROOT}/.config/starship.toml"
  [[ -f "$f" ]] || return 0

  # 【重要】U+100000 は UTF-8 で 4 バイト (f4 80 80 80)。
  # printf '\U100000' はロケール依存で C ロケールだと展開されないため、
  # Nerd Font のアイコンと同じくバイト列で直接指定する。
  local esca linux_icon
  esca=$(printf '\xf4\x80\x80\x80')
  linux_icon=$(printf '\xef\x85\xbc')   # U+F17C nf-fa-linux

  grep -q "$esca" "$f" 2>/dev/null || return 0

  run_cmd_soft "starship: Esca グリフを標準アイコンに置換" \
    sed -i "s/${esca}/${linux_icon}/g" "$f" || true

  # 説明コメントも実態と合わなくなるので併せて落とす。
  run_cmd_soft "starship: 廃止したフォントへの言及を削除" \
    sed -i '/EscaSymbols\.otf/d' "$f" || true

  print_ok "starship のプロンプト記号を標準アイコンに統一しました"
}

# 引き継いだ starship 設定のうち、Nerd Fonts v3 で削除された符号位置を差し替える。
#
# 【重要】v3 は U+F500-FD46 を廃止した。v2 時代の設定をそのまま持ち込むと、
# フォントは入っているのにその文字だけ豆腐(□)になる。
# Waybar 側 (write_waybar_config) には既に同じ置換があるが、
# starship.toml は別経路でコピーされるため、ここでも同様に処理する必要がある。
_fix_starship_nerdfont_v3() {
  local f="${SKEL_ROOT}/.config/starship.toml"
  [[ -f "$f" ]] || return 0

  # U+F83D (v3 で削除) -> U+F023 (nf-fa-lock, v3 でも有効)
  local old_lock new_lock
  old_lock=$(printf '\xef\xa0\xbd')
  new_lock=$(printf '\xef\x80\xa3')

  grep -q "$old_lock" "$f" 2>/dev/null || return 0
  run_cmd_soft "starship: Nerd Fonts v3 で削除された符号位置を置換" \
    sed -i "s/${old_lock}/${new_lock}/g" "$f" || true
  print_ok "starship: 廃止された符号位置のアイコンを現行のものに差し替えました"
}

# DE ごとに壁紙を既定として設定する。
# 引数1: DE 名 / 引数2: 壁紙のインストール先パス（ターゲット視点）
#
# 【方針】可能な限り「ユーザーのホーム」ではなく「システム既定」として設定する。
# skel に置く方式は、インストール後に作った2人目以降のユーザーや、DE 側が初回
# ログイン時に設定を再生成するケースで効かないことがあるため。
_set_de_wallpaper() {
  local de="$1" wp="$2"
  [[ -z "$wp" ]] && return 0

  case "$de" in
    gnome|budgie)
      # dconf のシステムデータベースで既定値を与える。
      # GNOME・Budgie とも org.gnome.desktop.background スキーマを使う。
      # 【重要】/etc/dconf/profile/user が無いと system-db が読まれない。
      # 既にある場合は壊さないよう、local 行が無いときだけ追記する。
      run_cmd "壁紙: dconf システム既定を配置 (${de})" bash -c "
        mkdir -p /mnt/etc/dconf/db/local.d /mnt/etc/dconf/profile
        if [[ ! -f /mnt/etc/dconf/profile/user ]]; then
          printf 'user-db:user\nsystem-db:local\n' > /mnt/etc/dconf/profile/user
        elif ! grep -q '^system-db:local$' /mnt/etc/dconf/profile/user; then
          printf 'system-db:local\n' >> /mnt/etc/dconf/profile/user
        fi
        cat > /mnt/etc/dconf/db/local.d/01-esca-background << EOF
[org/gnome/desktop/background]
picture-uri='file://${wp}'
picture-uri-dark='file://${wp}'
picture-options='zoom'
primary-color='#0d182c'

[org/gnome/desktop/screensaver]
picture-uri='file://${wp}'
picture-options='zoom'
primary-color='#0d182c'
EOF
      "
      # dconf update でバイナリDBを生成しないと設定が反映されない
      run_cmd_soft "壁紙: dconf データベース更新" arch-chroot /mnt dconf update || true
      print_ok "壁紙: ${de} の既定壁紙を設定しました"
      ;;

    cosmic)
      # cosmic-bg はシステム既定を /usr/share/cosmic/ 配下から読む
      # （パッケージ自身が同じ場所に既定値を置いている）。
      # 書式は RON。真偽値が #true 表記である点に注意（true では読めない）。
      run_cmd "壁紙: COSMIC システム既定を配置" bash -c "
        mkdir -p /mnt/usr/share/cosmic/com.system76.CosmicBackground/v1
        cat > /mnt/usr/share/cosmic/com.system76.CosmicBackground/v1/all << EOF
(
    output: \"all\",
    source: Path(\"${wp}\"),
    filter_by_theme: #true,
    rotation_frequency: 3600,
    filter_method: Lanczos,
    scaling_mode: Zoom,
    sampling_method: Alphanumeric,
)
EOF
      "
      print_ok "壁紙: COSMIC の既定壁紙を設定しました"
      ;;

    kde)
      # Plasma の壁紙はプラズマシェルの設定に埋め込まれており、初回ログイン時に
      # 生成される。そこで2段構えにする:
      #   1. 選択画面に出る正式な壁紙パッケージとして /usr/share/wallpapers/Esca を作る
      #   2. /etc/xdg にシステム既定を置き、初回生成時に拾わせる
      # 【要検証】2 のコンテナメントID(下記の [Containments][1]) は環境により
      # 異なる場合がある。効かなかった場合でも 1 があるので、設定画面から
      # "Esca" を選べば適用できる。実機で確認すること。
      # 【ライセンス】壁紙は AI による生成物を基にしているため、著作権が
      # 発生しない可能性が高い。CC BY-SA 4.0 は「著作権があること」を前提に
      # した継承ライセンスなので、権利の無いものに付けると表示と実態が食い違う。
      # 権利の有無にかかわらず矛盾しない CC0（パブリックドメイン提供）を使う。
      run_cmd "壁紙: KDE 壁紙パッケージを作成" bash -c "
        mkdir -p /mnt/usr/share/wallpapers/Esca/contents/images
        cp '/mnt${wp}' /mnt/usr/share/wallpapers/Esca/contents/images/1672x941.png
        cp '/mnt${wp}' /mnt/usr/share/wallpapers/Esca/contents/screenshot.png
        cat > /mnt/usr/share/wallpapers/Esca/metadata.json << 'EOF'
{
    \"KPlugin\": {
        \"Id\": \"Esca\",
        \"Name\": \"Esca\",
        \"License\": \"CC0 1.0\",
        \"Authors\": [ { \"Name\": \"Esca Linux\" } ]
    }
}
EOF
      "
      run_cmd "壁紙: KDE システム既定を配置" bash -c "
        mkdir -p /mnt/etc/xdg
        cat > /mnt/etc/xdg/plasma-org.kde.plasma.desktop-appletsrc << EOF
[Containments][1]
wallpaperplugin=org.kde.image

[Containments][1][Wallpaper][org.kde.image][General]
Image=file://${wp}
SlidePaths=/usr/share/wallpapers/
FillMode=2
EOF
      "
      print_ok "壁紙: KDE の既定壁紙を設定しました（設定画面にも \"Esca\" として表示されます）"
      ;;

    xfce)
      # xfconf のプロパティパスにはモニター名が入る
      # （例 /backdrop/screen0/monitorHDMI-1/workspace0/last-image）が、
      # インストール時点では実機のモニター名が分からない。
      # xfdesktop は該当プロパティが無い場合 monitor0 を見るため、そちらを書く。
      # 【要検証】モニター名付きプロパティが優先される環境では効かない可能性がある。
      run_cmd "壁紙: Xfce 既定を配置" bash -c "
        mkdir -p ${SKEL_ROOT}/.config/xfce4/xfconf/xfce-perchannel-xml
        cat > ${SKEL_ROOT}/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml << EOF
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<channel name=\"xfce4-desktop\" version=\"1.0\">
  <property name=\"backdrop\" type=\"empty\">
    <property name=\"single-workspace-mode\" type=\"bool\" value=\"true\"/>
    <property name=\"single-workspace-number\" type=\"int\" value=\"0\"/>
    <property name=\"screen0\" type=\"empty\">
      <property name=\"monitor0\" type=\"empty\">
        <property name=\"workspace0\" type=\"empty\">
          <property name=\"last-image\" type=\"string\" value=\"${wp}\"/>
          <property name=\"image-style\" type=\"int\" value=\"5\"/>
          <property name=\"color-style\" type=\"int\" value=\"0\"/>
          <property name=\"rgba1\" type=\"array\">
            <value type=\"double\" value=\"0.050980\"/>
            <value type=\"double\" value=\"0.094118\"/>
            <value type=\"double\" value=\"0.172549\"/>
            <value type=\"double\" value=\"1.000000\"/>
          </property>
        </property>
      </property>
    </property>
  </property>
</channel>
EOF
      "
      print_ok "壁紙: Xfce の既定壁紙を設定しました"
      ;;
  esac
}

# ============================================
# 一時 sudoers の後始末
# ============================================
# do_aur_helper は makepkg を非対話で回すため、対象ユーザーに一時的な
# NOPASSWD sudo を付与する。正常系では関数末尾で削除するが、AUR ビルドは
# 失敗しやすく、途中で異常終了すると「パスワード不要 sudo」が入ったままの
# システムが出来上がってしまう。そのため trap で確実に消す。
# ※ パスはグローバル変数に置く。local 変数を trap 文字列で参照すると、
#    EXIT 時には既に消えていて rm -f "/mnt" になりかねない。
AUR_TEMP_SUDOERS=""


_cleanup_temp_sudoers() {
  if [[ -n "${AUR_TEMP_SUDOERS:-}" ]] && [[ -e "/mnt${AUR_TEMP_SUDOERS}" ]]; then
    rm -f "/mnt${AUR_TEMP_SUDOERS}" 2>/dev/null || true
  fi
}

_on_interrupt() {
  _cleanup_temp_sudoers
  exit 130
}

# ============================================
# 予期しない終了の可視化
# ============================================
# set -e で停止すると何も表示されずにプロンプトへ戻るため、
# 「何も言わずに終了した」ように見えてしまう。どこで何が失敗したかを必ず出す。
_on_error() {
  local rc=$?
  # 【重要】ハンドラ内の $LINENO は「ハンドラ自身の行」になるため使えない。
  # 実際に失敗したコマンドの行は BASH_LINENO[0]、その呼び出し元は BASH_LINENO[1]。
  # ここを取り違えると、毎回この関数の行番号が「発生場所」として表示され、
  # 報告を受けても原因箇所に辿り着けなくなる。
  local line="${BASH_LINENO[0]:-?}"
  local caller_line="${BASH_LINENO[1]:-?}"
  local fn="${FUNCNAME[1]:-main}"
  echo ""
  echo -e "${RED}${BOLD}✘ 予期しないエラーで停止しました${RESET}"
  echo -e "${RED}  終了コード  : ${rc}${RESET}"
  echo -e "${RED}  失敗した処理: ${BASH_COMMAND}${RESET}"
  echo -e "${RED}  発生場所    : ${fn}() の ${line} 行目${RESET}"
  echo -e "${RED}  呼び出し元  : ${caller_line} 行目${RESET}"
  echo -e "${RED}  ログ        : ${CONFIG[log_file]:-未作成}${RESET}"
  echo ""
  echo -e "  ${GRAY}この内容をそのまま報告すると原因を特定できます。${RESET}"
  _cleanup_temp_sudoers
}

# ============================================
# ユーティリティ関数
# ============================================

# ============================================
# ブランディング
# ============================================
# Esca — チョウチンアンコウの発光する疑似餌。
# 深海で道を照らす光、という含意でこの名前にしている。
#
# 【重要】曲線部分に ╭ ╰ ╱ ● といった文字を使わないこと。
# Live ISO の VGA コンソールフォント（CP437 系）に含まれず、
# 化けて意味不明な表示になる。ASCII の . , ' - / \ で描く。
# 一方 █ ╔ ╗ ╚ ╝ ═ ║ ─ │ は CP437 に含まれるので安全。

readonly OS_NAME="Esca Linux"
readonly OS_ID="esca"
readonly OS_TAGLINE="日本語環境セットアップ"
# 【重要】プロジェクトの公開 URL。os-release と SDDM テーマの両方から参照する。
# os-release に書いた値はインストールした全システムに残り続けるため、
# 実在しない URL を入れると利用者側で恒久的にリンク切れになる。
# 2箇所に直書きすると片方だけ直し忘れるので、必ずここで一元管理すること。
readonly OS_HOME_URL="https://github.com/yannsi/esca_linux_installer"

# 起動時に一度だけ表示する大きいロゴ
print_logo() {
  clear
  echo ""
  echo -e "                    ${YELLOW}${DIM}. ${BOLD}*${RESET}${YELLOW}${DIM} .${RESET}"
  echo -e "                  ${YELLOW}${DIM}*${RESET}  ${YELLOW}${BOLD}(o)${RESET}  ${YELLOW}${DIM}*${RESET}"
  echo -e "                    ${YELLOW}${DIM}. ${BOLD}*${RESET}${YELLOW}${DIM} .${RESET}"
  echo -e "                      ${CYAN}|${RESET}"
  echo -e "               ${CYAN},------'${RESET}"
  echo -e "             ${CYAN},'${RESET}"
  echo -e "        ${CYAN}----'${RESET}"
  echo ""
  echo -e "  ${CYAN}${BOLD}███████╗███████╗ ██████╗ █████╗ ${RESET}"
  echo -e "  ${CYAN}${BOLD}██╔════╝██╔════╝██╔════╝██╔══██╗${RESET}"
  echo -e "  ${CYAN}${BOLD}█████╗  ███████╗██║     ███████║${RESET}"
  echo -e "  ${CYAN}${BOLD}██╔══╝  ╚════██║██║     ██╔══██║${RESET}"
  echo -e "  ${CYAN}${BOLD}███████╗███████║╚██████╗██║  ██║${RESET}"
  echo -e "  ${CYAN}${BOLD}╚══════╝╚══════╝ ╚═════╝╚═╝  ╚═╝${RESET}"
  echo ""
  echo -e "     ${DIM}Arch Linux ベース${RESET}  ${GRAY}·${RESET}  ${DIM}${OS_TAGLINE}${RESET}"
  echo ""
}

# 各ステップで表示するコンパクトなヘッダー。
# print_step から毎回呼ばれ画面をクリアするため、大きいロゴは使わない。
print_header() {
  clear
  echo ""
  echo -e "  ${YELLOW}${BOLD}(o)${RESET} ${CYAN}${BOLD}${OS_NAME}${RESET}  ${GRAY}│${RESET}  ${DIM}${OS_TAGLINE}${RESET}"
  echo -e "  ${CYAN}$(printf '━%.0s' {1..48})${RESET}"
  echo ""
}

print_step() {
  print_header
  if [[ "${STEP_TOTAL:-0}" -gt 0 ]]; then
    # 直前ステップの所要時間を記録（完了画面のサマリー用）
    if [[ -n "${CURRENT_STEP_NAME:-}" ]]; then
      STEP_LOG+=("${CURRENT_STEP_NAME}|$(( SECONDS - CURRENT_STEP_TS ))")
    fi
    CURRENT_STEP_NAME="$1"
    CURRENT_STEP_TS=$SECONDS
    STEP_NUM=$(( ${STEP_NUM:-0} + 1 ))
    echo -e "  ${MAGENTA}${BOLD}[${STEP_NUM}/${STEP_TOTAL}]${RESET} ${BLUE}${BOLD}▶ $1${RESET}"
    if [[ -n "${INSTALL_START:-}" ]]; then
      echo -e "  ${GRAY}経過時間: $(( (SECONDS - INSTALL_START) / 60 ))分$(( (SECONDS - INSTALL_START) % 60 ))秒${RESET}"
    fi
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

# 対話入力の共通読み取り。
# 素の `read` は EOF（パイプ実行・Ctrl+D・端末喪失）で非ゼロを返し、
# set -e により何のメッセージも出さずスクリプトが終了してしまう。
# 「何も言わず終了した」ように見える事故を防ぐため、必ずここを通す。
_read_input() {
  local -n _dest_ref="$1"
  local src="$2" dst="$3" mode="${4:-normal}"
  local rc=0
  if [[ "$mode" == "silent" ]]; then
    read -rs _dest_ref < "$src" || rc=$?
  else
    read -r _dest_ref < "$src" || rc=$?
  fi
  if [[ "$rc" -ne 0 ]]; then
    echo "" > "$dst"
    echo -e "  ${RED}✘ 入力を読み取れませんでした（入力が尽きたか、端末が切断されました）。${RESET}" > "$dst"
    echo -e "  ${GRAY}このスクリプトは対話式です。パイプ経由ではなく直接実行してください。${RESET}" > "$dst"
    echo -e "  ${GRAY}例: sudo bash install.sh${RESET}" > "$dst"
    exit 1
  fi
  _dest_ref="${_dest_ref:-}"
}

# コマンドをバックグラウンドで実行しつつ、5秒を超えたら経過時間を毎秒表示する。
# 長時間コマンド（pacstrap 等）がフリーズと区別できるようにするための内部ヘルパー。
# 終了コードをそのまま返す（exit はしない）。最終行の確定表示は呼び出し側が行う。
_exec_timed() {
  local desc="$1"; shift
  local start_ts=$SECONDS pid rc=0 elapsed
  "$@" >> "${CONFIG[log_file]}" 2>&1 < /dev/null &
  pid=$!
  # 【重要】ポーリング間隔を 1 秒固定にしないこと。
  # run_cmd 系の呼び出しは 170 回以上あり、その大半は 1 秒未満で終わる。
  # 固定 1 秒だと 1 回あたり平均 0.5 秒の取りこぼしが出て、合計で
  # 1分以上の「何もしていない待ち時間」になる。
  # 最初の5秒は細かく見て、長引く処理に入ったら 1 秒間隔へ落として CPU を使わない。
  while kill -0 "$pid" 2>/dev/null; do
    elapsed=$(( SECONDS - start_ts ))
    if [[ "$elapsed" -ge 5 ]]; then
      echo -ne "\r  ${CYAN}…${RESET} ${desc}... （$(( elapsed / 60 ))分$(( elapsed % 60 ))秒経過）  "
      sleep 1
    else
      sleep 0.1
    fi
  done
  # 注意: 「if ! wait ...」の形にすると $? が否定後の値（常に0）になるため、
  # 「|| rc=$?」で元の終了コードを取得する（set -e 下でも安全）
  rc=0
  wait "$pid" 2>/dev/null || rc=$?
  return "$rc"
}

run_cmd() {
  # コマンドを実行しログに残す。失敗時はエラー表示して終了
  local desc="$1"; shift
  echo -ne "  ${CYAN}…${RESET} ${desc}..."
  if [[ "${CONFIG[dry_run]}" == "yes" ]]; then
    echo -e "\r  ${YELLOW}⚠${RESET} ${desc} (ドライラン - スキップ)"
    return 0
  fi
  if _exec_timed "$desc" "$@"; then
    echo -e "\r  ${GREEN}✔${RESET} ${desc}                              "
  else
    echo -e "\r  ${RED}✘${RESET} ${desc} — 失敗                              "
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
    if _exec_timed "$desc" "$@"; then
      echo -e "\r  ${GREEN}✔${RESET} ${desc}                              "
      return 0
    fi
    echo -e "\r  ${YELLOW}⚠${RESET} ${desc} — 失敗 (試行 ${attempt}/${max_attempts})                              "
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
  if _exec_timed "$desc" "$@"; then
    echo -e "\r  ${GREEN}✔${RESET} ${desc}                              "
    return 0
  fi
  echo -e "\r  ${YELLOW}⚠${RESET} ${desc} — 失敗（スキップして継続）                              "
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
  _read_input answer "$tty_in" "$tty_out"
  echo "${answer:-$default}"
}

ask_password() {
  local prompt="$1"
  local pw1 pw2
  local tty_out tty_in; _resolve_tty tty_out tty_in
  while true; do
    echo -ne "  ${BOLD}${prompt}${RESET}: " > "$tty_out"
    _read_input pw1 "$tty_in" "$tty_out" silent; echo > "$tty_out"
    if [[ "$pw1" == *"|"* ]]; then
      echo -e "  ${RED}✘${RESET} パスワードに '|' は使用できません。" > "$tty_out"
      continue
    fi
    echo -ne "  ${BOLD}（確認）${prompt}${RESET}: " > "$tty_out"
    _read_input pw2 "$tty_in" "$tty_out" silent; echo > "$tty_out"
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
    _read_input answer "$tty_in" "$tty_out"
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
    _read_input answer "$tty_in" "$tty_out"
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
    _read_input choice "$tty_in" "$tty_out"
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
  local tmpfile rc=0
  tmpfile=$(mktemp)
  chmod 600 "$tmpfile"
  printf "%s:%s" "$user" "$pw" > "$tmpfile"
  # 【重要】chpasswd が失敗すると set -e でここから先に進まないため、
  # 素直に書くと rm -f に到達せず平文パスワードのファイルが /tmp に残る。
  # 「|| rc=$?」で失敗を受け止め、必ず消してから改めて失敗を伝える。
  arch-chroot /mnt chpasswd < "$tmpfile" || rc=$?
  rm -f "$tmpfile"
  if [[ "$rc" -ne 0 ]]; then
    print_err "${user} のパスワード設定に失敗しました（終了コード ${rc}）"
    return "$rc"
  fi
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
  sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/'                           "$conf"
  sed -i '/^#\[multilib\]/,/^#Include = \/etc\/pacman.d\/mirrorlist/s/^#//'        "$conf"
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
  local tty_out tty_in; _resolve_tty tty_out tty_in
  max="${#disks[@]}"
  while true; do
    echo -ne "  番号を入力: "
    _read_input choice "$tty_in" "$tty_out"
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
    "自動 - EFI 512M + swap (RAM同容量) + /（ハイバネート使用時）" \
    "手動（fdisk を起動）")

  case "$scheme" in
    "自動（推奨） - EFI 512M + / のみ（swap なし・zram 推奨）") CONFIG[partition_scheme]="auto_noswap" ;;
    "自動 - EFI 512M + swap (RAM同容量) + /（ハイバネート使用時）") CONFIG[partition_scheme]="auto_swap" ;;
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

  # --- キーボード配列: 日本語特化のため jp106 固定 ---
  # （US 配列キーボードを使う場合はインストール後に
  #   localectl set-keymap us / set-x11-keymap us で変更可能）
  CONFIG[keymap]="jp106"
  print_ok "キーマップ  : jp106（日本語 JIS 固定）"

  # --- 日本語入力 (IME): 日本語特化のため fcitx5 + Mozc 固定 ---
  CONFIG[jp_ime]="fcitx5-mozc"
  print_ok "IME         : fcitx5-mozc（固定）"

  # --- ホスト名 ---
  # 英数字とハイフンのみ許可（RFC 1123 準拠・63文字以内）。
  # 未検証のまま bash -c に埋め込むと ' などでコマンドが壊れるため必ず検証する。
  echo ""
  while true; do
    CONFIG[hostname]=$(ask "ホスト名" "archlinux")
    if [[ -z "${CONFIG[hostname]}" ]]; then
      print_err "ホスト名は必須です。"
      continue
    fi
    if [[ ! "${CONFIG[hostname]}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
      print_err "ホスト名は英数字とハイフンのみ・63文字以内です（先頭/末尾にハイフン不可）。"
      continue
    fi
    break
  done
  print_ok "ホスト名: ${CONFIG[hostname]}"

  # --- Windows デュアルブート ---
  #
  # 【重要】この設問は「Windows を保護するかどうか」ではない。
  # ここで yes にしても、パーティションは一切守られない。
  # 実際に変わるのは次の3点だけ:
  #   1. RTC を localtime にする（Windows との時刻ずれ防止）
  #   2. os-prober を導入する（GRUB のメニューに Windows を載せる）
  #   3. 自動パーティション併用時に最終確認を追加する
  # 利用者が「はい＝Windows が消えないように取り計らってくれる」と
  # 誤解すると、そのままディスク全体を消してしまう。
  # 設問文と説明で、守られないことを先に明示すること。
  echo ""
  echo "  Windows がインストールされた PC に、Windows を残したまま"
  echo "  Esca Linux を追加し、起動時にどちらを使うか選べるようにする設定です。"
  echo ""
  print_warn "この設定を「はい」にしても、Windows は自動では保護されません。"
  echo "      Windows を残すには、この後の「パーティション構成」で"
  echo "      必ず「手動（fdisk）」を選び、空き領域に作成してください。"
  echo "      「自動」を選ぶとディスク全体が消去され、Windows も消えます。"
  echo ""
  echo "  「はい」にすると次の3点が変わります:"
  echo "      ・ハードウェアクロックを Windows に合わせる（時刻がずれなくなる）"
  echo "      ・起動メニューに Windows を表示する（os-prober を導入）"
  echo "      ・ディスクを消す設定になっていないか、最後にもう一度確認する"
  echo ""
  echo "  Windows を使っていない場合や、このディスクの Windows を"
  echo "  消してしまってよい場合は「いいえ」を選んでください。"
  echo ""
  if confirm "Windows を残して、起動時に選べるようにしますか？"; then
    CONFIG[dualboot_windows]="yes"
    print_ok "RTC モード: localtime（Windows と時刻を合わせる）"
    print_ok "起動メニューに Windows を表示します（os-prober）"
    print_warn "Windows を残すには「手動（fdisk）」でのパーティション作成が必須です。"
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
    # 検出に成功した場合は確認せず自動採用する
    # （検出失敗時のみ下の手動選択にフォールバック）
    CONFIG[gpu_driver]="$recommended"
    print_ok "検出された GPU: ${detected_gpu} → ドライバー ${CONFIG[gpu_driver]} を自動選択"
    return
  fi

  print_warn "GPU を自動検出できませんでした。手動で選択してください。"
  echo ""

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

    # 追加のたびに確認表示を出す。
    # 【注意】以前は users_count -eq 1 のときだけ表示していたため、
    # 2人目以降は入力し終えても何も反応が返らず「追加されたのか分からない」状態だった。
    print_ok "ユーザー追加: ${uname} (sudo: ${usudo}, shell: ${ushell})"
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
      "フル  - kde-applications 全部入り（約4GB）")
    case "$kde_apps" in
      "最小（上級者・開発者向け）"*)     CONFIG[kde_apps]="minimal" ;;
      "標準  - plasma-meta + 基本アプリ（約1.5GB・推奨）") CONFIG[kde_apps]="standard" ;;
      "フル  - kde-applications 全部入り（約4GB）") CONFIG[kde_apps]="full" ;;
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
        "LightDM    - 軽量・X11/Wayland" \
        "greetd     - 最軽量・TUI" \
        "なし       - TTY から手動起動")
      ;;
    gnome)
      # 【重要】LightDM を選択肢に入れないこと。
      # GNOME 49 で Xorg セッション("GNOME on Xorg")が既定無効になり、
      # GNOME 50 で完全に削除された。現在の GNOME は
      # /usr/share/wayland-sessions/gnome.desktop しか持たない。
      # LightDM は X の greeter から /usr/share/xsessions/ のセッションを
      # 起動する前提の DM のため、GNOME セッションを立ち上げられず
      # 「ログイン直後に画面が真っ黒・マウスカーソルも出ない」状態で固まる。
      # ログにも分かりやすいエラーが出ないため原因の切り分けが非常に難しい（実機で確認）。
      #
      # greetd も非対応。greetd はセッションを「環境変数なしのコマンド」でしか
      # 起動できないが、GNOME は XDG_SESSION_TYPE=wayland + dbus-run-session が
      # 必要なため、素のコマンド起動では立ち上がらない
      # （tuigreet 公式もラッパー必須と明記）。
      dm=$(select_from_list "ディスプレイマネージャー (DM) を選択:" \
        "GDM        - GNOME 推奨・Wayland 対応（推奨）" \
        "SDDM       - Wayland セッション対応（GDM が合わない場合）" \
        "なし       - TTY から手動起動")
      ;;
    budgie)
      # Budgie は X11 セッション本体なので LightDM で問題ない。
      # greetd のみ非対応（X サーバ前提で、環境を整えるラッパーが無いと起動しない）。
      #
      # 【注意】gdm パッケージは gnome-shell / gnome-session に依存している。
      # Budgie で GDM を選ぶと、使わない GNOME のコアが一緒に入る。
      # 動作に支障は無く実績もある組み合わせなので選択肢からは外さないが、
      # 「知らないうちに GNOME が入っていた」とならないよう選択肢に明記する。
      # デスクトップ環境が GNOME に切り替わるわけではない（CONFIG[desktop] は不変）。
      dm=$(select_from_list "ディスプレイマネージャー (DM) を選択:" \
        "LightDM    - Budgie 推奨・軽量（推奨）" \
        "GDM        - GNOME 系で実績あり（gnome-shell も一緒に入ります）" \
        "SDDM       - 軽量・Wayland/X11" \
        "なし       - TTY から手動起動")
      ;;
    xfce)
      # greetd は非対応（Xfce は X11 セッションで、greetd からの素起動は前提外）
      dm=$(select_from_list "ディスプレイマネージャー (DM) を選択:" \
        "LightDM    - Xfce 推奨・軽量（推奨）" \
        "SDDM       - 軽量・Wayland/X11" \
        "なし       - TTY から手動起動")
      ;;
    cosmic)
      dm=$(select_from_list "ディスプレイマネージャー (DM) を選択:" \
        "cosmic-greeter - COSMIC 専用グリーター（推奨）" \
        "SDDM           - 軽量・Wayland/X11" \
        "greetd         - 最軽量・TUI" \
        "なし           - TTY から手動起動")
      ;;
    hyprland|niri)
      dm=$(select_from_list "ディスプレイマネージャー (DM) を選択:" \
        "greetd     - 最軽量・TUI（推奨）" \
        "SDDM       - GUI・Wayland/X11" \
        "なし       - TTY から手動起動")
      ;;
  esac

  # 選択肢はすべて select_from_list の固定文字列で先頭単語が一意なため、
  # 前方一致だけで確実に判定できる
  case "$dm" in
    SDDM*)             CONFIG[dm]="sddm" ;;
    GDM*)              CONFIG[dm]="gdm" ;;
    LightDM*)          CONFIG[dm]="lightdm" ;;
    "cosmic-greeter"*) CONFIG[dm]="cosmic-greeter" ;;
    greetd*)           CONFIG[dm]="greetd" ;;
    *)                 CONFIG[dm]="none" ;;
  esac

  # 防御ガード: メニューからは選べないはずだが、将来メニューを触ったときに
  # 起動しない組み合わせが復活しないようにここでも弾く。
  # （greetd は環境変数なしのコマンドしか起動できないため、自前で環境を整える
  #   ラッパーを持たない DE ではログイン後に何も立ち上がらない）
  case "${CONFIG[desktop]}:${CONFIG[dm]}" in
    gnome:greetd|budgie:greetd|xfce:greetd)
      print_warn "${CONFIG[desktop]} は greetd では起動できないため、SDDM に切り替えます。"
      CONFIG[dm]="sddm"
      ;;
    # 【重要】GNOME は Wayland セッションのみ（GNOME 49 で Xorg 廃止 / 50 で削除）。
    # LightDM は xsessions 前提の DM のため、ログイン直後に真っ黒な画面のまま固まる。
    gnome:lightdm)
      print_warn "GNOME は Wayland セッションのみのため LightDM では起動できません。GDM に切り替えます。"
      CONFIG[dm]="gdm"
      ;;
  esac

  print_ok "DM: ${CONFIG[dm]}"
}

# ============================================
# ステップ: 設定の引き継ぎ元（ホストPC / GitHub / なし）
# ============================================

# 指定ディレクトリ配下の .config から、引き継ぎ対象になる設定を列挙して表示する。
# step_config_source のホスト側/GitHub側の2箇所で使う。
# 引き継ぎ対象として「実際にコピーされるもの」だけを列挙する。
#
# 【重要】この一覧は do_desktop 側の app_configs / file_configs と必ず揃えること。
# かつては DE を問わず waybar/hypr/niri/fuzzel まで並べていたが、
# コピー処理側は「本体を導入する DE でしか設定も持ち込まない」方針で
# 絞り込んでいるため、GNOME や KDE を選んだ利用者には
# 「引き継ぐと表示されたのに引き継がれない」という食い違いが見えていた。
# 表示だけ広くしても実態は変わらないので、ここで同じ条件に揃える。
_inheritable_config_list() {
  local list=(mpv)
  # Waybar とその周辺ツールは Hyprland / Niri でしか導入しないため、
  # 他の DE では設定だけ持ち込んでも動かすものが無い。
  case "${CONFIG[desktop]}" in
    hyprland) list+=(waybar hypr fuzzel alacritty mako cava rofi swaylock ranger) ;;
    niri)     list+=(waybar niri fuzzel alacritty mako cava rofi swaylock ranger) ;;
  esac
  # 日本語入力は DE に依存しない。mozc のユーザー辞書と学習履歴が入っており、
  # ここを引き継げるかどうかが変換の使い勝手を大きく左右する。
  if [[ "${CONFIG[japanese_env]}" == "yes" && "${CONFIG[jp_ime]:-none}" =~ ^fcitx5 ]]; then
    list+=(fcitx5 mozc)
  fi
  printf '%s\n' "${list[@]}"
}

_print_inheritable_configs() {
  local dir="$1"
  local found=() c
  while IFS= read -r c; do
    [[ -e "${dir}/.config/${c}" ]] && found+=("$c")
  done < <(_inheritable_config_list)
  # starship.toml はディレクトリではなく単体ファイルなので個別に見る。
  [[ -e "${dir}/.config/starship.toml" ]] && found+=("starship")
  if [[ "${#found[@]}" -gt 0 ]]; then
    echo -e "    ${GRAY}引き継ぎ対象: ${found[*]}${RESET}"
  else
    echo -e "    ${GRAY}引き継ぎ対象になる設定は見つかりませんでした${RESET}"
  fi
}

step_config_source() {
  print_step "設定の引き継ぎ"

  # 何が利用可能かを先に調べて提示する。
  # 【重要】_host_home ではなく _host_home_raw を使うこと。
  # _host_home は CONFIG[config_source] を見て分岐するため、
  # 再実行（修正ループ）時に前回の選択が検出結果に混ざってしまう。
  local host_dir
  host_dir=$(_host_home_raw)

  case "${CONFIG[desktop]}" in
    hyprland|niri)
      echo -e "  ${GRAY}Waybar・${CONFIG[desktop]}・alacritty・fcitx5 などの設定を"
      echo -e "  新しい環境へ引き継ぐかどうかを選べます。${RESET}"
      ;;
    *)
      # 【重要】ここで Waybar や Hyprland を挙げないこと。
      # これらは Hyprland / Niri でしか導入せず、設定も持ち込まないため、
      # 他の DE の利用者に挙げると引き継がれない項目を期待させてしまう。
      echo -e "  ${GRAY}日本語入力（変換履歴・ユーザー辞書）や mpv などの設定を"
      echo -e "  新しい環境へ引き継ぐかどうかを選べます。${RESET}"
      echo -e "  ${GRAY}※ ${CONFIG[desktop]} 自体の外観・パネル設定は引き継ぎ対象外です"
      echo -e "     （Waybar など Hyprland/Niri 専用の設定は持ち込みません）。${RESET}"
      ;;
  esac
  echo ""

  if [[ -n "$host_dir" ]]; then
    print_ok "ホストPCの設定を検出: ${host_dir}"
    # 何が引き継がれるのか具体的に見せる（想像で選ばせない）
    _print_inheritable_configs "$host_dir"
  else
    print_warn "ホストPCの設定は見つかりませんでした（素の Live ISO から起動した場合など）"
  fi
  echo -e "  ${GRAY}GitHub リポジトリ: ${ESCA_DOTFILES_REPO} (${ESCA_DOTFILES_BRANCH})${RESET}"
  echo ""

  # 選択肢は「実際に選べるもの」だけを出す。
  # 使えない選択肢を並べて選ばせてから失敗させるのは不親切なため。
  # ただし GitHub からの取得は事前確認にネットワーク待ちが要るので、
  # 常に選択肢として出しておき、選ばれた時点で取得して結果を知らせる。
  local opts=()
  [[ -n "$host_dir" ]] && opts+=("ホストPCの設定を引き継ぐ  - 今の見た目・操作感をそのまま再現（推奨）")
  opts+=("GitHub から取得する        - ${ESCA_DOTFILES_REPO##*/} の最新設定を使う")
  opts+=("引き継がない              - 各パッケージの既定設定のみ（素の状態）")

  local sel
  sel=$(select_from_list "設定の引き継ぎ元を選択:" "${opts[@]}")
  case "$sel" in
    "ホストPCの設定を引き継ぐ"*) CONFIG[config_source]="host" ;;
    "GitHub から取得する"*)      CONFIG[config_source]="git" ;;
    *)                            CONFIG[config_source]="none" ;;
  esac

  # GitHub を選んだ場合はこの場で取得まで済ませる。
  # インストール本番（do_desktop）まで失敗が分からないと、
  # 「設定が入らなかった理由」が分かりにくくなるため。
  if [[ "${CONFIG[config_source]}" == "git" ]]; then
    echo -ne "  ${CYAN}…${RESET} GitHub から dotfiles を取得中..."
    local git_dir
    git_dir=$(_git_dotfiles)
    if [[ -n "$git_dir" ]]; then
      echo -e "\r  ${GREEN}✔${RESET} GitHub から dotfiles を取得しました      "
      _print_inheritable_configs "$git_dir"
      # かつてこのリポジトリは niri 専用で .config/hypr を持たなかった。
      # 現在は含まれているためこの警告は通常発火しないが、リポジトリ側の
      # 構成変更で再び欠けることはありうるので、判定は残しておく。
      if [[ "${CONFIG[desktop]}" == "hyprland" && ! -d "${git_dir}/.config/hypr" ]]; then
        print_warn "このリポジトリには .config/hypr が無いため、Hyprland 本体の設定はパッケージ既定になります（Waybar などの周辺設定は引き継がれます）。"
      fi
    else
      echo -e "\r  ${YELLOW}⚠${RESET} GitHub から dotfiles を取得できませんでした"
      print_warn "引き継ぎなし（既定設定のみ）に切り替えます。ネットワークまたはリポジトリURLを確認してください。"
      CONFIG[config_source]="none"
    fi
  fi

  case "${CONFIG[config_source]}" in
    host)    print_ok "設定の引き継ぎ: ホストPC (${host_dir})" ;;
    git)     print_ok "設定の引き継ぎ: GitHub (${ESCA_DOTFILES_REPO})" ;;
    none)    print_ok "設定の引き継ぎ: なし（既定設定のみ）" ;;
  esac
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

  # 高品質フォント（Adobe 源ノ）: 日本語特化のため固定で導入
  pkgs+=(adobe-source-han-sans-jp-fonts adobe-source-han-serif-jp-fonts)
  print_ok "源ノ角ゴシック + 源ノ明朝 を追加（固定）"

  # プログラミング向け等幅フォント: 軽量のため固定で導入
  pkgs+=(ttf-fira-code)
  print_ok "ttf-fira-code を追加（固定）"

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

  # zram（圧縮RAMスワップ）: 推奨のため固定で有効化
  CONFIG[extra_zram]="yes"
  print_ok "zram         : 有効（固定・RAM 上の圧縮スワップ）"

  # fstrim.timer（SSD の定期 TRIM）: 固定で有効化
  # （HDD 環境では単に何もしないだけで害はない）
  CONFIG[extra_fstrim]="yes"
  print_ok "fstrim.timer : 有効（固定・SSD の定期 TRIM）"
  echo ""

  # OpenSSH サーバー（セキュリティに関わるため質問を残す）
  if confirm_yes "OpenSSH サーバーをインストール・有効化しますか？（リモート接続用・推奨）"; then
    CONFIG[extra_ssh]="yes"; print_ok "OpenSSH を有効化（sshd を自動起動）"
  else
    CONFIG[extra_ssh]="no"; print_ok "OpenSSH はスキップ"
  fi

  # LibreOffice（デスクトップ環境選択時のみ）
  # 依存込みで 1GB 近くあるため、ミニマル構成を望むユーザー向けに選択制にする
  if [[ "${CONFIG[desktop]:-none}" != "none" ]]; then
    if confirm_yes "LibreOffice（オフィススイート・約1GB）をインストールしますか？（推奨）"; then
      CONFIG[install_office]="yes"; print_ok "LibreOffice を導入"
    else
      CONFIG[install_office]="no"; print_ok "LibreOffice はスキップ"
    fi
  else
    CONFIG[install_office]="no"
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
      # ヘルパーは yay 固定（paru を使いたい上級者は後から自分で導入できる）
      CONFIG[aur_helper]="yay"
      print_ok "AUR ヘルパー: yay（固定）"
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
  # 【重要】ここを `[[ -n "$extra" ]] && print_ok ...` と書いてはいけない。
  # 関数の最後の文になるため、$extra が空（＝Enter だけ押した通常の操作）だと
  # 関数の戻り値が 1 になり、set -e で呼び出し元ごと即死する。
  # 「何も言わずに終了する」現象の原因になっていた。
  if [[ -n "$extra" ]]; then
    print_ok "追加パッケージ: $extra"
  fi
}

# ============================================

# ============================================
# ホスト環境の検出（クローンモード用）
# ============================================
# クローンでは「ホストと同じ DE・DM」が唯一の正解になるため、
# ユーザーに選ばせず実体から判定する。
# 実機で判明した通り、ホストの設定（niri 用の fcitx5 autostart 無効化など）は
# DE が違うと毒になる。選択肢を消すことが確実な対処になる。




# ホストのパッケージ一覧を収集してファイルに書き出す。
# 戻り値: 0 = 収集できた / 1 = 収集できない環境

# ============================================
# ステップ: インストールモードの選択
# ============================================


# ============================================
# ステップ: ホスト環境のクローン
# ============================================
# このスクリプトを「今使っている Arch」から実行して別ディスクに入れる場合、
# ホスト側の pacman DB を読めば「普段使っているアプリ一式」がそのまま分かる。
# それを新環境にも入れることで、環境の作り直しをコマンド1回に短縮する。

# インストーラ自身が決めるもの・ハードウェア固有のものは複製しない。
# （ホストが NVIDIA でも新マシンが Intel なら nvidia は不要、など）


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
  echo -e "  ${BOLD}Windows 共存  :${RESET} $([[ "${CONFIG[dualboot_windows]:-no}" == "yes" ]] && echo "する（起動時に選択・時刻を Windows に合わせる）" || echo "しない（時刻は UTC・推奨）")"
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
  echo -e "  ${BOLD}ミラー          :${RESET} reflector (Japan・固定)"
  echo -e "  ${BOLD}デスクトップ  :${RESET} ${CONFIG[desktop]}"
  [[ "${CONFIG[desktop]}" == "kde" ]] && \
    echo -e "  ${BOLD}KDE アプリ規模 :${RESET} ${CONFIG[kde_apps]}"
  echo -e "  ${BOLD}DM            :${RESET} ${CONFIG[dm]:-none}"
  # 設定の引き継ぎ元を日本語で表示する（host/git/none のままだと分かりにくい）
  local _cfgsrc_label
  case "${CONFIG[config_source]:-host}" in
    host)    _cfgsrc_label="ホストPCの設定" ;;
    git)     _cfgsrc_label="GitHub (${ESCA_DOTFILES_REPO##*/})" ;;
    *)       _cfgsrc_label="なし（既定設定のみ）" ;;
  esac
  echo -e "  ${BOLD}設定の引き継ぎ :${RESET} ${_cfgsrc_label}"
  echo -e "  ${BOLD}GPU ドライバ   :${RESET} ${CONFIG[gpu_driver]}"
  echo -e "  ${BOLD}base-devel    :${RESET} ${CONFIG[extra_base_devel]}"
  echo -e "  ${BOLD}AUR ヘルパー   :${RESET} ${CONFIG[aur_helper]}"
  echo -e "  ${BOLD}Google Chrome :${RESET} ${CONFIG[install_chrome]:-no}"
  echo -e "  ${BOLD}yt-fzf-sh     :${RESET} ${CONFIG[install_ytfzf]:-no}"
  echo -e "  ${BOLD}OpenSSH       :${RESET} ${CONFIG[extra_ssh]}"
  echo -e "  ${BOLD}ufw (FW)      :${RESET} ${CONFIG[extra_ufw]}"
  echo -e "  ${BOLD}zram          :${RESET} ${CONFIG[extra_zram]}"
  echo -e "  ${BOLD}fstrim.timer  :${RESET} ${CONFIG[extra_fstrim]:-no}"
  if [[ "${CONFIG[desktop]:-none}" != "none" ]]; then
    echo -e "  ${BOLD}LibreOffice   :${RESET} ${CONFIG[install_office]:-no}"
  fi
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
    if [[ "${CONFIG[dry_run]}" == "yes" ]]; then
      print_warn "ドライランのため fdisk 起動をスキップします"
      return
    fi
    print_warn "fdisk を起動します。終了後 Enter を押してください。"
    fdisk "$disk"
    return
  fi

  # ハイバネート用 swap サイズ: RAM と同容量（GiB 切り上げ・最低 4G）を確保する。
  # 固定 4G だと RAM が 4GB を超えるマシンでハイバネートに失敗するため。
  local swap_size="4G"
  if [[ "$scheme" == "auto_swap" ]]; then
    local mem_kb
    mem_kb=$(grep -m1 '^MemTotal' /proc/meminfo | awk '{print $2}')
    if [[ "$mem_kb" =~ ^[0-9]+$ ]] && [[ "$mem_kb" -gt 0 ]]; then
      local mem_gib=$(( (mem_kb + 1048575) / 1048576 ))
      [[ "$mem_gib" -lt 4 ]] && mem_gib=4
      swap_size="${mem_gib}G"
    fi
    print_ok "swap サイズ: ${swap_size}（ハイバネート用に RAM 同容量を確保）"
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
      # swap (RAM 同容量)
      run_cmd "swap パーティション作成 (${swap_size})" \
        sgdisk --new=2:0:+"${swap_size}" --typecode=2:8200 --change-name=2:swap "$disk"
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
      run_cmd "swap パーティション作成 (${swap_size})" \
        sgdisk --new=2:0:+"${swap_size}" --typecode=2:8200 --change-name=2:swap "$disk"
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
    if [[ "${CONFIG[dry_run]}" == "yes" ]]; then
      print_warn "ドライランのため手動マウント処理をスキップします"
      return
    fi
    echo ""
    print_warn "手動パーティションモードです。"

    local mount_method
    mount_method=$(select_from_list "マウント方法を選択してください:" \
      "対話型アシスタントを使用（推奨・スクリプト内でマウントを指定）" \
      "手動でマウントする（別ターミナルなどでマウント済みの状態にする）")

    if [[ "$mount_method" == "対話型アシスタントを使用（推奨・スクリプト内でマウントを指定）" ]]; then
      echo ""
      print_warn "検出されたパーティション一覧:"
      lsblk -p "$disk" 2>/dev/null || fdisk -l "$disk" 2>/dev/null || ls "/sys/block/${disk#/dev/}/" || true
      echo ""

      local root_p=""
      while true; do
        root_p=$(ask "Root (/) パーティションのデバイスパスを指定してください (例: /dev/sda2)")
        if [[ -b "$root_p" ]]; then
          break
        fi
        print_err "有効なブロックデバイスではありません: $root_p"
      done

      if confirm "Root パーティション ($root_p) を ${CONFIG[fs_type]:-ext4} でフォーマットしますか？（※既存データは消去されます）"; then
        _format_root "$root_p"
      fi
      _mount_root "$root_p"
      CONFIG[root_part]="$root_p"

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
          CONFIG[swap_part]="$swap_p"
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

    # 「別ターミナルで自分でマウントした」場合は CONFIG が空のままなので、
    # 実際のマウント状態から root / swap を逆引きしておく。
    # これを埋めておかないと resume フックとカーネルの resume= がズレる。
    if [[ -z "${CONFIG[root_part]}" ]]; then
      CONFIG[root_part]=$(findmnt -no SOURCE /mnt 2>/dev/null | head -n1 | sed 's/\[.*\]$//')
      [[ -n "${CONFIG[root_part]}" ]] && print_ok "root パーティションを検出: ${CONFIG[root_part]}"
    fi
    if [[ -z "${CONFIG[swap_part]}" ]]; then
      CONFIG[swap_part]=$(swapon --show=NAME --noheadings 2>/dev/null | head -n1)
      [[ -n "${CONFIG[swap_part]}" ]] && print_ok "swap パーティションを検出: ${CONFIG[swap_part]}"
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
    CONFIG[root_part]="$root_part"
    CONFIG[swap_part]="$swap_part"

    echo "[DEBUG] EFI フォーマット開始: $efi_part" >> "${CONFIG[log_file]}"
    run_cmd "EFI フォーマット (FAT32)"  mkfs.fat -F32 "$efi_part"
    echo "[DEBUG] root フォーマット開始: $root_part (fs=${CONFIG[fs_type]})" >> "${CONFIG[log_file]}"
    _format_root "$root_part"
    echo "[DEBUG] _format_root 完了" >> "${CONFIG[log_file]}"
    if [[ -n "$swap_part" ]]; then
      run_cmd "swap フォーマット" mkswap "$swap_part"
    fi
    echo "[DEBUG] _mount_root 開始: $root_part" >> "${CONFIG[log_file]}"
    _mount_root "$root_part"
    echo "[DEBUG] _mount_root 完了" >> "${CONFIG[log_file]}"
    run_cmd "EFI ディレクトリ作成" mkdir -p /mnt/boot
    echo "[DEBUG] EFI マウント開始: $efi_part" >> "${CONFIG[log_file]}"
    run_cmd "EFI マウント" mount -t vfat "$efi_part" /mnt/boot
    echo "[DEBUG] EFI マウント完了" >> "${CONFIG[log_file]}"
    # 【重要】`[[ -n ... ]] && run_cmd ... || true` と書かないこと。
    # swap_part が空のときだけでなく、swapon が「失敗したとき」も || true が
    # 拾ってしまい、swap が有効化できていないのに成功扱いで先へ進む。
    # 条件は必ず if で明示し、run_cmd の失敗はそのまま止める。
    if [[ -n "$swap_part" ]]; then
      run_cmd "swap 有効化" swapon "$swap_part"
    fi

  else
    # BIOS（efi_part/swap_part/root_part は関数先頭で local 宣言済み）
    if [[ "$scheme" == "auto_swap" ]]; then
      swap_part=$(part_suffix "$disk" 2)
      root_part=$(part_suffix "$disk" 3)
    else
      root_part=$(part_suffix "$disk" 2)
    fi
    CONFIG[root_part]="$root_part"
    CONFIG[swap_part]="$swap_part"

    _format_root "$root_part"
    # 【重要】UEFI 側と同じ理由で `&& ... || true` は使わない。
    if [[ -n "$swap_part" ]]; then
      run_cmd "swap フォーマット" mkswap "$swap_part"
    fi

    _mount_root "$root_part"
    if [[ -n "$swap_part" ]]; then
      run_cmd "swap 有効化" swapon "$swap_part"
    fi
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

  # systemd-resolved: 推奨のため固定で有効化
  # （DNS キャッシュ・DNSSEC。NetworkManager と自動連携する）
  CONFIG[use_resolved]="yes"
  print_ok "systemd-resolved: 有効（固定）"
}

# ============================================
# ステップ: ミラーサーバー設定
# ============================================

step_mirror() {
  print_step "ミラーサーバー設定"

  # 日本語特化のため reflector --country Japan 固定。
  # （reflector 失敗時のフォールバックは do_mirrorlist 側で処理）
  CONFIG[mirror_country]="Japan"
  print_ok "ミラー: reflector で日本国内の速いミラーを自動選択（固定）"
}

# ============================================
# 実行: ミラーリスト設定
# ============================================

do_mirrorlist() {
  print_step "ミラーリスト設定"

  # 日本語特化のため reflector（--country Japan）固定
  # reflector が入っていなければインストール
  if ! command -v reflector &>/dev/null; then
    run_cmd_retry "reflector インストール" pacman -S --noconfirm reflector
  fi

  # 日本国内・HTTPS・最終同期24時間以内・速度順 上位8件
  run_cmd_retry "reflector 実行（Japan・速度順）" \
    reflector --country "${CONFIG[mirror_country]:-Japan}" \
      --protocol https \
      --age 24 \
      --sort rate \
      --number 8 \
      --save /etc/pacman.d/mirrorlist
  print_ok "選択されたミラー:"
  grep '^Server' /etc/pacman.d/mirrorlist | sed 's/^/    /' || true
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
  # ※ この -Sy でパッケージDBも同時に更新されるため、追加の -Syy は不要
  #   （-Syy は全ミラーDBの強制再取得で、直後に行うと単なる二重ダウンロードになる）
  run_cmd_retry "Live ISO キーリング更新 + パッケージDB更新" pacman -Sy --noconfirm archlinux-keyring

  # 【重要】vim を入れても `vi` コマンドは使えない。
  # Arch は vi パッケージの提供を終了しており、vim パッケージは
  # /usr/bin/vi を作らないため、vi と打つと command not found になる。
  # ex-vi-compat が /usr/bin/vi と /usr/bin/ex を vim へのシンボリックリンクとして
  # 提供するので、これを併せて入れる。
  # （visudo や systemctl edit は EDITOR 未設定時に vi を呼ぶため、
  #   これが無いと編集そのものが起動しない場面がある）
  local pkgs=(base sudo linux linux-firmware sof-firmware networkmanager vim ex-vi-compat)

  # ファイルシステム操作ツール一式
  # GNOME Disks や KDE Partition Manager などの GUI は mkfs.* を外部コマンドとして
  # 呼び出すため、これらが無いと「フォーマット形式の候補に出てこない」状態になる。
  # base には dosfstools すら含まれないので、DE の有無に関わらずここで入れる。
  local fs_tools=(
    dosfstools    # FAT12/16/32 — SD カード・USB メモリ・EFI で最頻出
    exfatprogs    # exFAT — 大容量 SD カード、デジカメ
    ntfs-3g       # NTFS のマウント用 FUSE ドライバ
    # 【重要】mkfs.ntfs / mkntfs は ntfs-3g には入っていない。
    # Arch は 2026年5月に ntfs-3g を分割し、ドライバ = ntfs-3g、
    # ユーティリティ = ntfsprogs になった（以前は provides で同一だった）。
    # これが無いと GUI に NTFS のフォーマット候補が出てこない。
    ntfsprogs     # NTFS の作成・修復・リサイズ (mkntfs, ntfsfix, ntfsresize)
    btrfs-progs   # Btrfs
    xfsprogs      # XFS
    f2fs-tools    # F2FS — フラッシュメモリ向け
    udftools      # UDF — 光学メディア・大容量可搬メディア
    e2fsprogs     # ext2/3/4（base にも含まれるが依存を明示する）
    mtools        # FAT をマウントせずに操作する
    parted        # パーティション操作（GUI ツールが libparted 経由で使う）
  )
  pkgs+=("${fs_tools[@]}")

  # root のファイルシステムに応じた案内（パッケージ自体は上で導入済み）
  case "${CONFIG[fs_type]:-ext4}" in
    btrfs) print_ok "root は Btrfs（btrfs-progs 導入済み）" ;;
    xfs)   print_ok "root は XFS（xfsprogs 導入済み）" ;;
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

  # コンソール（TTY）フォント。
  # 既定の 8x16 フォントは高解像度パネルだと極端に小さく読みにくい。
  # また X / Wayland が起動しない障害時に TTY だけが復旧手段になるため、
  # デスクトップの有無に関わらず全インストールで入れておく。
  pkgs+=(terminus-font)

  # starship プロンプト（全インストール共通）。
  # 【重要】do_desktop 側ではなくここで入れること。
  # do_desktop は desktop=none で早期 return するため、そちらに置くと
  # CLI のみの構成でプロンプト初期化だけが .bashrc に残り、
  # シェルを開くたびに starship が見つからない状態になる
  # （init 側は command -v で守ってあるが、本体が無いこと自体が想定外）。
  pkgs+=(starship)

  # 汎用 CLI ツール（全インストール共通）。
  # 【重要】starship と同じ理由で do_desktop 側ではなくここに置くこと。
  # do_desktop は desktop=none で早期 return するため、そちらに置くと
  # CLI のみの構成にだけ入らない。これらはターミナルから使う道具なので、
  # デスクトップ環境の有無で入る／入らないが変わるのは筋が通らない。
  #
  # かつて streamlink を Hyprland / Niri の pkgs にだけ置いていた時期があり、
  # 「GNOME に streamlink が入らない」という取りこぼしが実際に起きた。
  # 特定の WM やパネルの依存として扱わず、必ずこの一箇所で管理する。
  # 5つとも公式リポジトリ (extra) にあるため AUR ヘルパーは不要。
  pkgs+=(
    streamlink      # 各種配信サイトのストリーム取得（mpv へ引き渡し）
    yt-dlp          # 動画・音声のダウンロード
    sox             # 音声の変換・加工・再生 (play/rec/sox)
    imagemagick     # 画像の変換・リサイズ・一括処理 (magick)
    qrencode        # QR コード生成
  )

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
    # Windows デュアルブート時は他OS検出のため os-prober を追加
    # （NTFS のマウントに必要な ntfs-3g は fs_tools で導入済み）
    if [[ "${CONFIG[dualboot_windows]}" == "yes" ]]; then
      pkgs+=(os-prober)
      print_ok "デュアルブート用に os-prober を追加"
    fi
  fi

  # AURヘルパー/Chrome/yt-fzf 用 git の追加（いずれも clone + makepkg を使う）
  # AUR 接続確認そのものが `arch-chroot /mnt git ls-remote ...` で git を使うため、
  # git が無いとこの確認が失敗し、「AUR に接続できません／DNS の同期不良」という
  # 実態と異なる警告を出したまま処理が進む。
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
        || "${CONFIG[install_ytfzf]:-no}" == "yes" \
        || "${CONFIG[desktop]}" == "hyprland" \
        || "${CONFIG[desktop]}" == "niri" ]]; then
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
  if [[ -f /mnt/etc/fstab ]]; then
    print_ok "生成内容:"
    sed 's/^/    /' /mnt/etc/fstab
  fi
}

# ============================================
# 実行: chroot 内設定
# ============================================

# ============================================
# OS ブランディングの書き込み
# ============================================
# /etc/os-release と /etc/issue に Esca Linux の情報を書く。
#
# 【注意】Arch の /etc/os-release は filesystem パッケージが所有する
# /usr/lib/os-release へのシンボリックリンク。実ファイルで置き換えると、
# filesystem の更新時に pacman が os-release.pacnew を作る。
# 正式には自前の filesystem パッケージを用意するべきだが、
# 独自リポジトリを持つまではこの方式で問題ない。
write_os_branding() {
  run_cmd "OS 情報の書き込み (/etc/os-release)" bash -c "
    rm -f /mnt/etc/os-release
    cat > /mnt/etc/os-release <<'OSREL'
NAME=\"${OS_NAME}\"
PRETTY_NAME=\"${OS_NAME} (Arch Linux ベース)\"
ID=${OS_ID}
ID_LIKE=arch
BUILD_ID=rolling
ANSI_COLOR=\"1;33\"
HOME_URL=\"${OS_HOME_URL}\"
LOGO=${OS_ID}
OSREL
  "

  # TTY ログイン画面のバナー。\\e や \\l は agetty が解釈するため
  # ヒアドキュメントをクォートして、ここでは展開させない。
  run_cmd "コンソールバナーの書き込み (/etc/issue)" bash -c "
    cat > /mnt/etc/issue <<'ISSUE'

                    . * .
                  *  (o)  *
                    . * .
                      |
               ,------'
             ,'
        ----'

  ███████╗███████╗ ██████╗ █████╗
  ██╔════╝██╔════╝██╔════╝██╔══██╗
  █████╗  ███████╗██║     ███████║
  ██╔══╝  ╚════██║██║     ██╔══██║
  ███████╗███████║╚██████╗██║  ██║
  ╚══════╝╚══════╝ ╚═════╝╚═╝  ╚═╝

  Arch Linux ベース  ·  \\r on \\m

ISSUE
  "
}

do_chroot_config() {
  print_step "chroot 内設定"

  # タイムゾーン・時刻設定
  run_cmd "タイムゾーン設定" \
    arch-chroot /mnt ln -sf "/usr/share/zoneinfo/${CONFIG[timezone]}" /etc/localtime

  if [[ "${CONFIG[dualboot_windows]:-no}" == "yes" ]]; then
    # Windows と共存: RTC をローカル時刻として扱う
    # timedatectl は chroot 内で動かないため /etc/adjtime を直接書く
    # ※ hwclock は RTC の無い一部の VM で失敗するため非致命扱い
    #   （挙動を決めるのは adjtime の書き込みなのでそちらが本命）
    # 【重要】run_cmd_soft は失敗時に 1 を返す。set -e 下で「|| true」を付けずに
    # 単独の文として呼ぶと、そこでインストーラ全体が停止してしまい
    # 「非致命扱い」という意図がそのまま無効になる。必ず || true を付けること。
    run_cmd_soft "RTC ローカル時刻設定（Windows 互換）" \
      arch-chroot /mnt hwclock --systohc --localtime || true
    # adjtime の3行目を LOCAL に確実に上書き（>> だと二重追記になるため > で書き直す）
    run_cmd "adjtime LOCAL 設定" bash -c \
      "printf '0.0 0 0.0\n0\nLOCAL\n' > /mnt/etc/adjtime"
  else
    # 通常: RTC を UTC として扱う（推奨）
    run_cmd_soft "RTC UTC 設定" arch-chroot /mnt hwclock --systohc --utc || true
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

  # 【重要】FONT は KEYMAP と同じ /etc/vconsole.conf に書く。
  # 以前は KEYMAP 行だけを `>` で書き出していたため、ここで FONT を
  # 別途追記しようとすると上書きで消える。1回の書き出しにまとめる。
  #
  # ter-116n = Terminus 8x16 通常字形。標準フォントと同じ高さのまま
  # 字形が読みやすくなる無難な既定値。高解像度パネルで小さすぎる場合は
  # ter-124n / ter-132n（12x24 / 16x32）に変更する。
  #
  # 【注意】コンソールフォントは PSF 形式で収録グリフ数に上限があり、
  # Nerd Font のアイコンや Powerline 区切り記号は表示できない。
  # TTY で starship の記号が豆腐になる場合はフォントではなくプリセット側で
  # 対処する（starship preset plain-text-symbols）。
  run_cmd "キーマップ・コンソールフォント設定" \
    bash -c "printf 'KEYMAP=%s\nFONT=ter-116n\n' '${CONFIG[keymap]}' > /mnt/etc/vconsole.conf"

  # X11 キーボードレイアウト設定
  # キーマップは jp106 固定のため X11 レイアウトも jp 固定
  local xkb_layout="jp"
  local xkb_model="jp106"

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
      # キーマップは jp106 固定のためレイアウトも jp 固定
      local layout="jp"
      local kb_item="keyboard-jp"

      # 選択された IME に応じて既定 IM を切り替える
      # （fcitx5-anthy 選択時に mozc を参照すると壊れたプロファイルになるため）
      local default_im="mozc"
      [[ "${CONFIG[jp_ime]}" == "fcitx5-anthy" ]] && default_im="anthy"

      run_cmd "Fcitx5 プロファイル初期設定" bash -c "
        mkdir -p ${SKEL_ROOT}/.config/fcitx5
        cat > ${SKEL_ROOT}/.config/fcitx5/profile << EOF
[Groups/0]
Name=Default
Default Layout=${layout}
DefaultIM=${default_im}

[Groups/0/Items/0]
Name=${kb_item}
Layout=

[Groups/0/Items/1]
Name=${default_im}
Layout=
EOF
      "
      print_ok "Fcitx5: 日本語入力の初期レイアウト・${default_im} を設定しました"
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
    <test name=\"family\"><string>Hack Nerd Font</string></test>
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
  # 判定は partition_scheme ではなく「実際に swap があるか」で行う。
  # do_bootloader は scheme に関わらず swap があれば resume=PARTUUID= を渡すため、
  # auto_swap 限定にすると手動パーティション+swap でフックだけ欠けて不整合になる。
  if [[ -n "${CONFIG[swap_part]}" ]]; then
    run_cmd "mkinitcpio.conf に resume フックを追加" bash -c "
      if grep -q '^HOOKS=' /mnt/etc/mkinitcpio.conf; then
        # アドレス指定なしだとコメント内の例示 HOOKS 行まで書き換わるため /^HOOKS=/ に限定
        sed -i '/^HOOKS=/ s/\bfilesystems\b/resume filesystems/' /mnt/etc/mkinitcpio.conf
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
    # MODULES に nvidia を入れた場合、HOOKS の kms は外す。
    # kms が残っていると initramfs に nouveau が同梱され、早期 KMS で
    # プロプライエタリドライバと競合して黒画面になることがある（Arch Wiki 推奨）。
    run_cmd "mkinitcpio.conf から kms フックを除去 (NVIDIA)" bash -c "
      sed -i '/^HOOKS=/ s/\bkms[[:space:]]*//' /mnt/etc/mkinitcpio.conf
    "
    # nouveau をモジュールレベルでも無効化（KMS 競合の二重防止）
    run_cmd "nouveau のブラックリスト設定" bash -c "
      mkdir -p /mnt/etc/modprobe.d
      echo 'blacklist nouveau' > /mnt/etc/modprobe.d/nvidia-blacklist-nouveau.conf
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
    # systemctl enable だけではファイアウォールは有効にならない
    # （ufw.service は起動時に /etc/ufw/ufw.conf の ENABLED を参照する）。
    # chroot 内で「ufw enable」は実行できないため、設定ファイルを直接書き換える。
    run_cmd "ufw 有効化フラグ設定 (ENABLED=yes)" bash -c "
      if grep -q '^ENABLED=' /mnt/etc/ufw/ufw.conf 2>/dev/null; then
        sed -i 's/^ENABLED=.*/ENABLED=yes/' /mnt/etc/ufw/ufw.conf
      else
        echo 'ENABLED=yes' >> /mnt/etc/ufw/ufw.conf
      fi
    "
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
  run_cmd "fish スケルディレクトリ作成" mkdir -p ${SKEL_ROOT}/.config/fish

  # bash が選ばれている場合のみ .bash_profile に追記
  if echo "${CONFIG[users]}" | grep -q '|bash|'; then
    run_cmd "bash xdg-user-dirs-update 設定" bash -c "cat >> ${SKEL_ROOT}/.bash_profile << 'EOF'

# 初回ログイン時にユーザーディレクトリを自動作成
if [ -x /usr/bin/xdg-user-dirs-update ]; then
  xdg-user-dirs-update
fi
EOF"
  fi

  # zsh が選ばれている場合のみ .zprofile に追記
  if echo "${CONFIG[users]}" | grep -q '|zsh|'; then
    run_cmd "zsh xdg-user-dirs-update 設定" bash -c "cat >> ${SKEL_ROOT}/.zprofile << 'EOF'

# 初回ログイン時にユーザーディレクトリを自動作成
if [ -x /usr/bin/xdg-user-dirs-update ]; then
  xdg-user-dirs-update
fi
EOF"
  fi

  # fish が選ばれている場合のみ config.fish に追記
  if echo "${CONFIG[users]}" | grep -q '|fish|'; then
    run_cmd "fish xdg-user-dirs-update 設定" bash -c "cat >> ${SKEL_ROOT}/.config/fish/config.fish << 'EOF'

# 初回ログイン時にユーザーディレクトリを自動作成
if test -x /usr/bin/xdg-user-dirs-update
  xdg-user-dirs-update
end
EOF"
  fi

  # ── starship プロンプトの初期化 ──
  # 【重要】do_desktop ではなくここで行うこと。以前は Hyprland / Niri のときだけ
  # 設定していたため、GNOME や KDE、CLI のみの構成では starship を入れても
  # プロンプトが素のままで、「入れたのに何も変わらない」状態だった。
  # starship.toml を置くだけでは何も起きず、シェルの rc で init を呼んで初めて効く。
  #
  # 【重要】.bash_profile ではなく .bashrc に書くこと。プロンプトは対話シェルごとに
  # 必要で、ログインシェルでしか読まれない profile に置くと端末を開き直すたびに
  # 素のプロンプトへ戻る。
  # 【重要】コマンドの存在を確認してから eval すること。starship が入っていない
  # 環境でこの行が走ると、シェル起動のたびに command not found が表示される。
  # 【注意】heredoc は必ず << 'EOF'（クォート付き）で書くこと。
  # 本文の $(starship init ...) はインストール先のシェルが実行時に評価する式であり、
  # ここで展開されてはいけない。run_cmd + bash -c "..." で包むと二重クォートの
  # エスケープが絡んで壊れやすいため、他の設定生成と同じく直接 heredoc で書き出す。
  if echo "${CONFIG[users]}" | grep -q '|bash|'; then
    cat >> ${SKEL_ROOT}/.bashrc << 'EOF'

# starship プロンプト（設定: ~/.config/starship.toml）
if command -v starship > /dev/null 2>&1; then
  eval "$(starship init bash)"
fi
EOF
    print_ok "bash: starship プロンプトを設定しました"
  fi
  if echo "${CONFIG[users]}" | grep -q '|zsh|'; then
    cat >> ${SKEL_ROOT}/.zshrc << 'EOF'

# starship プロンプト（設定: ~/.config/starship.toml）
if command -v starship > /dev/null 2>&1; then
  eval "$(starship init zsh)"
fi
EOF
    print_ok "zsh: starship プロンプトを設定しました"
  fi
  if echo "${CONFIG[users]}" | grep -q '|fish|'; then
    cat >> ${SKEL_ROOT}/.config/fish/config.fish << 'EOF'

# starship プロンプト（設定: ~/.config/starship.toml）
if type -q starship
    starship init fish | source
end
EOF
    print_ok "fish: starship プロンプトを設定しました"
  fi

  # Chromium / Electron 系アプリの Wayland / IME 連携設定
  if [[ "${CONFIG[desktop]}" != "none" ]]; then
    run_cmd "Chromium/Electron 向け Wayland IME 連携設定" bash -c "
      mkdir -p ${SKEL_ROOT}/.config
      cat > ${SKEL_ROOT}/.config/chrome-flags.conf << 'EOF'
--ozone-platform-hint=auto
--enable-wayland-ime
EOF
      cp ${SKEL_ROOT}/.config/chrome-flags.conf ${SKEL_ROOT}/.config/chromium-flags.conf
      cp ${SKEL_ROOT}/.config/chrome-flags.conf ${SKEL_ROOT}/.config/electron-flags.conf
      cp ${SKEL_ROOT}/.config/chrome-flags.conf ${SKEL_ROOT}/.config/code-flags.conf
    "
  fi

  # --- Typora 向け IME 起動ラッパー ---
  # 【実機で判明】/usr/bin/typora は AUR パッケージが独自に差し替えたラッパー
  # スクリプト（PKGBUILD が上流の bin リンクを削除して typora.sh を設置している）。
  # そのラッパーが読むのは typora-flags.conf のみで、上の electron-flags.conf は
  # 参照されないため効かない。
  # さらに wlroots WM (Hyprland/Niri) が対応するのは text-input-v3 のみで、
  # Typora 同梱の古い Electron は text-input-v1 しか喋れないため、
  # Wayland ネイティブで起動すると日本語入力が一切効かない（無反応になる）。
  # XWayland 側へ載せれば fcitx5 の GTK IM モジュール経由で入力できる。
  #
  # 【なぜ typora-flags.conf ではなくラッパーを置くのか】
  # typora-flags.conf は各ユーザーのホームに配る形になるため、ユーザーが
  # 消したり上書きしたりすると元に戻る。/usr/local/bin なら全ユーザーに確実に効く。
  # /usr/local/bin は既定で /usr/bin より前にあるため、PATH 設定が不要。
  # また typora.desktop の Exec は "typora %U" と相対パスなので、
  # fuzzel などのランチャー経由でも PATH 解決によりこのラッパーが使われる。
  #
  # 【将来】Typora の同梱 Electron が text-input-v3 に対応したら、XWayland を
  # 経由せず "--enable-wayland-ime" を渡す方式に切り替えたほうがきれいになる。
  if [[ "${CONFIG[desktop]}" == "niri" || "${CONFIG[desktop]}" == "hyprland" ]]; then
    run_cmd "Typora 向け IME 起動ラッパー作成" bash -c "
      mkdir -p /mnt/usr/local/bin
      cat > /mnt/usr/local/bin/typora << 'TYPORAEOF'
#!/bin/sh
# Typora を XWayland 上で起動し、fcitx5 経由の日本語入力を有効にする
# (Typora 同梱 Electron が Wayland の text-input-v3 に非対応なため)
if [ ! -x /usr/bin/typora ]; then
  echo 'typora がインストールされていません (AUR: typora)' >&2
  exit 127
fi
exec /usr/bin/typora --ozone-platform-hint=x11 \"\$@\"
TYPORAEOF
      chmod +x /mnt/usr/local/bin/typora
    "
    print_ok "Typora: XWayland 経由で起動するラッパーを /usr/local/bin に設置しました"
  fi

  # OS 名・バナーの書き込み
  write_os_branding

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

  # 【重要】ループ内の upw="" はローカル変数を消しているだけで、
  # CONFIG[users] には全ユーザーの平文パスワードが入ったまま残る。
  # 以降で users を参照するのは「ユーザー名の一覧」だけなので、
  # パスワード欄を空にした形に詰め直しておく。
  local _sanitized="" _e
  while IFS= read -r _e; do
    [[ -z "$_e" ]] && continue
    parse_users_line "$_e"
    if [[ -z "$_sanitized" ]]; then
      _sanitized="${uname}||${usudo}|${ushell}|${ugroups}"
    else
      _sanitized="${_sanitized}
${uname}||${usudo}|${ushell}|${ugroups}"
    fi
  done <<< "${CONFIG[users]}"
  CONFIG[users]="$_sanitized"
  upw=""

  # root パスワード
  # 【注意】この分岐は「root パスワードの有無」で判定している。
  # 一般ユーザーの有無とは別の話なので、メッセージを取り違えないこと。
  if [[ -n "${CONFIG[root_password]}" ]]; then
    _set_password "root" "${CONFIG[root_password]}"
    CONFIG[root_password]=""  # メモリ上の平文パスワードをクリア
    print_ok "root パスワードを設定しました。"
  else
    print_warn "root パスワードが未設定です。root では直接ログインできません。"
  fi

  if [[ "${CONFIG[users_count]:-0}" -eq 0 ]]; then
    print_warn "一般ユーザーが作成されていません。root アカウントのみになります。"
  fi
}
do_bootloader() {
  print_step "ブートローダーのインストール"

  local disk="${CONFIG[disk]}"
  local scheme="${CONFIG[partition_scheme]}"
  local root_part
  local swap_part=""
  local swap_partuuid=""

  # do_format_and_mount で確定済みならそれを使う（manual でも再質問しない）。
  # ここで CONFIG を信頼することで、resume フック（do_chroot_config）と
  # resume= カーネルパラメータが必ず同じ swap を指すようになる。
  if [[ -n "${CONFIG[root_part]}" ]]; then
    root_part="${CONFIG[root_part]}"
    swap_part="${CONFIG[swap_part]}"
    print_ok "パーティション: root=${root_part}${swap_part:+ / swap=${swap_part}}"
  elif [[ "$scheme" == "manual" ]]; then
    # 手動パーティション時はパーティション番号が不定なのでユーザーに確認
    print_warn "手動パーティションモードのため、ブートローダー用にパーティションを確認します。"
    lsblk -p "$disk" 2>/dev/null || fdisk -l "$disk" 2>/dev/null || ls "/sys/block/${disk#/dev/}/" || true
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

  # btrfs はルートを subvol=@ でマウントしているため、カーネルに rootflags を渡す。
  # これが無いと initramfs がトップレベルボリューム（@ や @home が並ぶ階層）を
  # ルートとしてマウントし、init が見つからず起動に失敗する。
  # （GRUB は grub-mkconfig が自動で付与するため systemd-boot のみ明示する）
  local sb_rootflags=""
  [[ "${CONFIG[fs_type]:-ext4}" == "btrfs" ]] && sb_rootflags=" rootflags=subvol=@"

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
options root=PARTUUID=${root_partuuid}${sb_rootflags} rw quiet${extra_options}
EOF"

    # フォールバックエントリ
    run_cmd "arch-fallback.conf 作成" bash -c "cat > /mnt/boot/loader/entries/arch-fallback.conf << EOF
title   Arch Linux (fallback)
linux   /vmlinuz-linux
${ucode_line}initrd  /initramfs-linux-fallback.img
options root=PARTUUID=${root_partuuid}${sb_rootflags} rw${extra_options}
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
      # 隠しディレクトリを使い、ホーム直下に見えるフォルダを残さない
      bd="$HOME/.cache/aur-build"; mkdir -p "$bd"; cd "$bd"
      for i in 1 2 3; do
        rm -rf "'"${dir}"'"
        git clone --depth=1 "'"${giturl}"'" "'"${dir}"'" && break
        echo "git clone に失敗、リトライ ($i/3)"; sleep 5
        [ "$i" = 3 ] && exit 1
      done
      cd "'"${dir}"'"
      makepkg -si --noconfirm --needed
      # ビルドディレクトリと、空になった作業用の親ディレクトリを削除する
      cd "$HOME"; rm -rf "$bd/'"${dir}"'"
      rmdir "$bd" 2>/dev/null || true
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


  # いずれも不要ならスキップ
  [[ "$helper" == "none" && "$want_chrome" != "yes" && "$want_ytfzf" != "yes" ]] && return

  # STEP_TOTAL に計上済みのため、スキップ時もステップ表示を先に行う
  print_step "追加パッケージのインストール（AUR ヘルパー / Chrome / yt-fzf / 電源メニュー）"

  # 代表ユーザー名を取得（CONFIG[users] の最初のユーザー）
  local first_user
  first_user=$(cut -d'|' -f1 <<< "$(head -n1 <<< "${CONFIG[users]}")")
  if [[ -z "$first_user" ]]; then
    print_warn "一般ユーザーが登録されていないため、追加パッケージのインストールをスキップします。"
    return
  fi

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
  # 異常終了時に trap（_cleanup_temp_sudoers）が消せるようグローバルにも控える
  AUR_TEMP_SUDOERS="$temp_sudoers"
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
      # クリップボード連携(PKGBUILD の optdepend)。
      # 【重要】「全DEが Wayland だから wl-clipboard」で決め打ちしないこと。
      # Xfce は X11 セッションなので wl-clipboard は一切動かず、
      # 「URL をコピーしても貼り付けられない」状態になる。X11 では xclip を使う。
      # DE 無し（CLI のみ）ならどちらも不要。
      local clip_pkg=""
      case "${CONFIG[desktop]}" in
        xfce) clip_pkg="xclip" ;;
        none) clip_pkg="" ;;
        *)    clip_pkg="wl-clipboard" ;;
      esac
      if [[ -n "$clip_pkg" ]]; then
        run_cmd_soft "${clip_pkg} 導入（yt-fzf のクリップボード連携）" \
          arch-chroot /mnt pacman -S --noconfirm --needed "$clip_pkg" || true
      fi
    else
      print_warn "yt-fzf-sh のインストールに失敗しました（後から手動で導入できます）"
    fi
  fi

  # 一時的な sudo 設定を削除
  run_cmd "一時的な sudo NOPASSWD 設定の削除" rm -f "/mnt${temp_sudoers}"
  AUR_TEMP_SUDOERS=""
}

# ============================================
# ユーティリティ: Waybar 設定ファイルを生成
# 引数1: WM 名（hyprland / niri）
# ============================================

# スクリーンショット保存用スクリプトを skel に配置する。
# grim/slurp をそのまま使うと保存先が英語の ~/Pictures にフォールバックし、
# 日本語のユーザーディレクトリ（~/ピクチャ）と別に英語フォルダが増えてしまう。
# COSMIC 用の日本語フォント設定を /etc/skel に配置する。
# COSMIC のシェルは cosmic-text（独自フォントDB）で描画し、fontconfig の
# locale ベース match ルールを読まない。既定の Open Sans / Noto Sans Mono には
# 日本語グリフが無く、フォールバックで漢字が中国語字形(SC)になるため、
# COSMIC 自身の設定でシステム/等幅フォントを JP 付きファミリに固定する。
# 設定形式は libcosmic の CosmicTk(version=1) に準拠（各項目が個別ファイル・RON）。
write_cosmic_font_config() {
  [[ "${CONFIG[dry_run]}" == "yes" ]] && return 0
  local tk_dir="${SKEL_ROOT}/.config/cosmic/com.system76.CosmicTk/v1"
  run_cmd "COSMIC 日本語フォント設定を配置" bash -c "mkdir -p '$tk_dir' && \
cat > '$tk_dir/interface_font' << 'EOF'
(
    family: \"Noto Sans CJK JP\",
    weight: Normal,
    stretch: Normal,
    style: Normal,
)
EOF
cat > '$tk_dir/monospace_font' << 'EOF'
(
    family: \"Noto Sans Mono CJK JP\",
    weight: Normal,
    stretch: Normal,
    style: Normal,
)
EOF"
  print_ok "COSMIC: システム/等幅フォントを日本語字形(JP)に固定しました"

  # COSMIC のアプリはそれぞれ独自のフォント設定を持ち、既定は "Noto Sans Mono"
  # （日本語グリフ無し）。CosmicTk を直しても各アプリには波及しないため、
  # 個別に font_name を JP 付き等幅ファミリへ固定する。
  # font_name は String 型なので、中身は引用符付きの RON 文字列 1 行。
  # 対象: テキストエディタ(CosmicEdit) / ターミナル(CosmicTerm)、いずれも v1。
  local app
  for app in CosmicEdit CosmicTerm; do
    local app_dir="${SKEL_ROOT}/.config/cosmic/com.system76.${app}/v1"
    run_cmd "COSMIC ${app} フォント設定を配置" bash -c \
      "mkdir -p '$app_dir' && printf '%s' '\"Noto Sans Mono CJK JP\"' > '$app_dir/font_name'"
  done
  print_ok "COSMIC: エディタ・ターミナルのフォントを日本語字形(JP)に固定しました"
}

# COSMIC 上での LibreOffice メニュー無反応の回避。
# LibreOffice の各ランチャー(.desktop)を /etc/skel にコピーし、Exec 行に
# 「env SAL_USE_VCLPLUGIN=gtk3 GDK_BACKEND=x11」を前置した上書き版を置く。
# ・SAL_USE_VCLPLUGIN=gtk3 : gtk3 系 VCL プラグインを使う
# ・GDK_BACKEND=x11        : gtk3 を XWayland 経由で動かし popup 不具合を回避
# GDK_BACKEND は他の GTK アプリに影響しないよう、全体設定にはせず
# LibreOffice のランチャーだけに閉じ込める。install_office=yes のときのみ実行。
write_libreoffice_cosmic_launchers() {
  [[ "${CONFIG[dry_run]}" == "yes" ]] && return 0
  [[ "${CONFIG[install_office]:-no}" == "yes" ]] || return 0
  run_cmd "COSMIC: LibreOffice ランチャーを XWayland 経由に上書き" bash -c '
    shopt -s nullglob
    dst=${SKEL_ROOT}/.local/share/applications
    mkdir -p "$dst"
    found=0
    for f in /mnt/usr/share/applications/libreoffice-*.desktop; do
      sed "s|^Exec=|Exec=env SAL_USE_VCLPLUGIN=gtk3 GDK_BACKEND=x11 |" \
        "$f" > "$dst/$(basename "$f")"
      found=1
    done
    [ "$found" -eq 1 ]
  ' || print_warn "LibreOffice の .desktop が見つからず、ランチャー上書きをスキップしました"
}

# xdg-user-dir PICTURES で「実際のピクチャディレクトリ（日本語名）」を解決し、
# そこへ保存することで、日本語フォルダ名を保ったままスクショ先を一致させる。
write_screenshot_script() {
  [[ "${CONFIG[dry_run]}" == "yes" ]] && return 0
  mkdir -p ${SKEL_ROOT}/.local/bin
  cat > ${SKEL_ROOT}/.local/bin/screenshot.sh << 'SSEOF'
#!/bin/sh
# 使い方: screenshot.sh [area|screen]   （既定: area=範囲選択）
# 保存先は xdg-user-dir が返す「ピクチャ」ディレクトリ（日本語名でもOK）。
mode="${1:-area}"

# ピクチャディレクトリを解決（未設定なら $HOME/ピクチャ を使う）
pic_dir="$(xdg-user-dir PICTURES 2>/dev/null)"
[ -z "$pic_dir" ] && pic_dir="$HOME/ピクチャ"
save_dir="$pic_dir/スクリーンショット"
mkdir -p "$save_dir"

file="$save_dir/$(date +%Y-%m-%d_%H-%M-%S).png"

case "$mode" in
  screen) grim "$file" ;;
  *)      grim -g "$(slurp)" "$file" ;;
esac

# 撮影に成功したらクリップボードにもコピーし、通知を出す
if [ -f "$file" ]; then
  wl-copy < "$file" 2>/dev/null || true
  command -v notify-send >/dev/null 2>&1 &&     notify-send "スクリーンショット" "保存しました: $file" || true
fi
SSEOF
  chmod +x ${SKEL_ROOT}/.local/bin/screenshot.sh
  print_ok "スクリーンショット保存スクリプトを配置（保存先: ~/ピクチャ/スクリーンショット）"
}

# Nerd Font のグリフ（U+E000-F8FF）を UTF-8 バイト列として出力する。
#
# 【重要】printf '\uXXXX' を使ってはいけない。あれはロケール依存で、
# C ロケール（Live ISO の既定になりうる）では変換されず、
# 文字列 "\uf001" がそのまま出力される。実際にこれで waybar のアイコンが
# 壊れた。UTF-8 のバイト列を直接組み立てればロケールに影響されない。
# 設定ファイルに一行を「まだ無ければ」追記する（niri の config.kdl / Hyprland の
# hyprland.conf 共用）。
# 【重要】ホストPC の設定を土台に使う場合、fcitx5・polkit エージェント・waybar などの
# 自動起動が既に書かれていることがある。素朴に追記するとログインのたびに二重起動し、
# fcitx5 では「変換候補が二つ出る」「入力切替が効かない」といった再現しにくい不具合になる。
# 【重要】パターンは行頭のキーワードで固定すること。緩いパターンはコメントアウト済みの
# 行にも一致し、「設定済み」と誤判定して必要な行を入れ損ねる。
# 使い方: _conf_append_once "$cfg" '検索する ERE' '追記する行'
_conf_append_once() {
  local cfg="$1" pattern="$2" line="$3"
  [[ -f "$cfg" ]] || return 0
  grep -qE "$pattern" "$cfg" && return 0
  echo "$line" >> "$cfg"
}

# バージョン比較: $1 >= $2 なら真（sort -V を利用。カレンダーバージョニング
# （niriの "26.04" 等）にも数値バージョン（Hyprlandの "0.56.1" 等）にも使える）。
_version_ge() {
  [[ "$1" == "$2" ]] && return 0
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ]]
}

# ホストPCの設定ファイル、または本スクリプトの既定設定生成ロジックを
# 「検証した時点のバージョン」と、実際にインストールされたバージョンが
# 離れていないかを警告する。
# 【重要】ここで処理を止めない。設定ファイル・生成ロジックの多くは後方互換が
# あるため、警告だけ出して先に進める（壊れていれば実機テストで気付ける形にする）。
# 引数1: pacman パッケージ名
# 引数2: 検証済みバージョン（例 "0.56"。前方一致で比較するため厳密な一致は不要）
# 引数3: 表示用の名前（例 "Hyprland" / "niri"）
# 引数4: 用途（"host"=ホストPCの設定を使う場合 / "base"=パッケージ既定を使う場合）
_check_pkg_version_gap() {
  local pkg="$1" verified="$2" label="$3" context="${4:-host}"
  local installed
  # 【重要】本スクリプトは set -euo pipefail。pacman -Q がパッケージ未検出で
  # 非0を返すと pipefail によりパイプ全体が非0になり、代入文がそのまま
  # set -e でスクリプトを落としてしまう（既知の "silent exit" 系バグと同種）。
  # `|| true` で明示的に握りつぶし、単に installed が空のまま return 0 させる。
  installed=$(arch-chroot /mnt pacman -Q "$pkg" 2>/dev/null | awk '{print $2}') || true
  [[ -z "$installed" ]] && return 0
  if [[ "$installed" != "${verified}"* ]]; then
    if [[ "$context" == "host" ]]; then
      print_warn "${label}: インストールされたバージョン(${installed})が、ホストPCの設定を検証したバージョン(${verified}系)と異なります。構文が非互換になっていないか確認してください。"
    else
      print_warn "${label}: インストールされたバージョン(${installed})が、この既定設定生成ロジックを検証したバージョン(${verified}系)と異なります。動作を確認してください。"
    fi
  fi
}

_nf() {
  local cp=$((16#$1))
  local b1=$(( 0xE0 | (cp >> 12) ))
  local b2=$(( 0x80 | ((cp >> 6) & 0x3F) ))
  local b3=$(( 0x80 | (cp & 0x3F) ))
  printf '%b' "\\x$(printf %x "$b1")\\x$(printf %x "$b2")\\x$(printf %x "$b3")"
}

# ============================================
# ユーティリティ: Hyprland の Lua 設定 (hyprland.lua) を生成
# 引数1: 壁紙の絶対パス（空なら背景色で代替）
# ============================================
# Hyprland 0.55 以降、設定は hyprlang(hyprland.conf) から Lua(hyprland.lua) へ
# 移行した。hyprland.lua があればそちらだけが読まれ、無ければ hyprland.conf が
# 読まれた上で非推奨バナーが出る。バナーを消し、将来 .conf 対応が外れても
# 壊れないようにするため、既定設定はこちらで生成する。
#
# 【重要】この関数が書く API 名（hl.config / hl.bind / hl.dsp.* / hl.curve /
# hl.animation / hl.env / hl.on / hl.window_rule）は Hyprland 0.55.4 に同梱の
# example/hyprland.lua で実在を確認したもの。憶測で API を足さないこと。
# Lua の構文エラーは Hyprland が設定の読み込み自体を拒否してエラーを出すため、
# 非推奨バナーより悪化する。
#
# 【重要】hl.config({ autogenerated = true }) は絶対に書かないこと。
# この行があると「自動生成された設定です」という黄色い警告が出続ける。
#
# 【重要】色の表記が hyprlang と異なる。
# hyprlang の rgba(RRGGBBAA) に対し、Lua の数値リテラルは 0xAARRGGBB。
# 例: rgba(00000088) → 0x88000000。並びを取り違えると色が化ける。
write_hyprland_lua_base() {
  local cfg="${SKEL_ROOT}/.config/hypr/hyprland.lua"
  mkdir -p "${SKEL_ROOT}/.config/hypr"

  # ── 本体（設定ソース非依存の部分）──
  # 【注意】heredoc は << 'LUAEOF'（クォート付き）で書くこと。
  # Lua 側の .. 連結や $ を含む文字列をシェルに展開させない。
  cat > "$cfg" << 'LUAEOF'
-- ============================================
-- Esca Linux - Hyprland 設定 (Lua)
-- 参考: https://wiki.hypr.land/Configuring/Start/
-- 設定はこのファイルを保存した瞬間に再読み込みされる。
-- 手動で読み直す場合は: hyprctl reload
-- ============================================

------------------
---- モニター ----
------------------
-- 【重要】scale に "auto" を使わないこと。
-- Hyprland の auto は 1.6 のような「論理サイズが整数ピクセルに割り切れない」
-- 倍率を選ぶことがあり、その場合 Hyprland が内部で値を丸める。すると
-- クライアントが想定するサイズと実際の描画サイズがズレて、次が同時に起きる:
--   ・Waybar（レイヤーサーフェス）が想定より大きく描かれる
--   ・ツールチップの座標計算が狂って画面外に出る＝「出ない」ように見える
--   ・fuzzel の --anchor=top-right が効かず、ポップアップが画面中央に出る
-- 実機で3症状が同時に出たため固定値にする。
--
-- 文字が小さすぎる場合は 1.25 / 1.5 / 2 に変える。
-- 1.6 や 1.75 のような値は同じ問題を再発させやすいので避けること。
hl.monitor({
    output   = "",
    mode     = "preferred",
    position = "auto",
    scale    = 1,
})

--------------------
---- よく使うもの ----
--------------------
local terminal    = "kitty"
local fileManager = "nautilus"
local menu        = "wofi --show drun"
local mainMod     = "SUPER"

--------------------
---- 見た目 ----
--------------------
hl.config({
    general = {
        gaps_in     = 5,
        gaps_out    = 10,
        border_size = 2,

        col = {
            -- Esca のフィラメントブルー（アンコウの発光をイメージした色）
            active_border   = { colors = { "rgba(1ca2f1ee)", "rgba(3bc7ffee)" }, angle = 45 },
            inactive_border = "rgba(0d1c2eaa)",
        },

        resize_on_border = true,
        allow_tearing    = false,
        layout           = "dwindle",
    },

    decoration = {
        rounding         = 12,
        active_opacity   = 1.0,
        inactive_opacity = 0.93,

        shadow = {
            enabled        = true,
            range          = 14,
            render_power   = 3,
            color          = 0x88000000,
            color_inactive = 0x44000000,
        },

        blur = {
            enabled = true,
            size    = 8,
            passes  = 3,
        },
    },

    animations = {
        enabled = true,
    },

    dwindle = {
        preserve_split = true,
    },

    misc = {
        force_default_wallpaper = 0,
        disable_hyprland_logo   = true,
        animate_manual_resizes  = true,
        mouse_move_enables_dpms = true,
        key_press_enables_dpms  = true,
    },
})

--------------------
---- アニメーション ----
--------------------
hl.curve("easeOut", { type = "bezier", points = { {0.16, 1},  {0.3,  1}    } })
hl.curve("easeIn",  { type = "bezier", points = { {0.7,  0},  {0.84, 0}    } })
hl.curve("linear",  { type = "bezier", points = { {0, 0},     {1, 1}       } })
hl.curve("easy",    { type = "spring", mass = 1, stiffness = 71.2633, dampening = 15.8273644 })

hl.animation({ leaf = "global",     enabled = true, speed = 10,   bezier = "default" })
hl.animation({ leaf = "windows",    enabled = true, speed = 4.79, spring = "easy" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 1.49, bezier = "easeIn",  style = "popin 80%" })
hl.animation({ leaf = "border",     enabled = true, speed = 5.39, bezier = "easeOut" })
hl.animation({ leaf = "fade",       enabled = true, speed = 3.03, bezier = "easeOut" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 1.94, bezier = "easeOut", style = "slidevert" })

--------------------
---- キーバインド ----
--------------------
hl.bind(mainMod .. " + Q", hl.dsp.exec_cmd(terminal))
hl.bind(mainMod .. " + C", hl.dsp.window.close())
hl.bind(mainMod .. " + E", hl.dsp.exec_cmd(fileManager))
hl.bind(mainMod .. " + D", hl.dsp.exec_cmd(menu))
hl.bind(mainMod .. " + R", hl.dsp.exec_cmd(menu))
hl.bind(mainMod .. " + V", hl.dsp.window.float({ action = "toggle" }))
hl.bind(mainMod .. " + J", hl.dsp.layout("togglesplit"))

-- 初心者向け
hl.bind(mainMod .. " + SHIFT + F", hl.dsp.exec_cmd(fileManager))
hl.bind(mainMod .. " + SHIFT + W", hl.dsp.exec_cmd("firefox"))

-- Waybar の表示切り替え
hl.bind(mainMod .. " + B", hl.dsp.exec_cmd("pkill waybar || waybar"))

-- フォーカス移動
hl.bind(mainMod .. " + left",  hl.dsp.focus({ direction = "left" }))
hl.bind(mainMod .. " + right", hl.dsp.focus({ direction = "right" }))
hl.bind(mainMod .. " + up",    hl.dsp.focus({ direction = "up" }))
hl.bind(mainMod .. " + down",  hl.dsp.focus({ direction = "down" }))

-- ワークスペース切り替え / ウィンドウ移動
-- hyprlang では9行ほぼ同じ行を並べる必要があったが、Lua ならループで書ける。
for i = 1, 10 do
    local key = i % 10 -- 10 はキー 0 に対応
    hl.bind(mainMod .. " + " .. key,         hl.dsp.focus({ workspace = i }))
    hl.bind(mainMod .. " + SHIFT + " .. key, hl.dsp.window.move({ workspace = i }))
end

-- マウス操作
hl.bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mainMod .. " + mouse_up",   hl.dsp.focus({ workspace = "e-1" }))
hl.bind(mainMod .. " + mouse:272",  hl.dsp.window.drag(),   { mouse = true })
hl.bind(mainMod .. " + mouse:273",  hl.dsp.window.resize(), { mouse = true })

-- 音量・輝度（locked = ロック画面でも有効 / repeating = 長押しで連続）
hl.bind("XF86AudioRaiseVolume",  hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+"), { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume",  hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"),      { locked = true, repeating = true })
hl.bind("XF86AudioMute",         hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"),     { locked = true })
hl.bind("XF86AudioMicMute",      hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"),   { locked = true })
hl.bind("XF86MonBrightnessUp",   hl.dsp.exec_cmd("brightnessctl set 10%+"),                         { locked = true, repeating = true })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("brightnessctl set 10%-"),                         { locked = true, repeating = true })

-- メディアキー（playerctl）
hl.bind("XF86AudioNext",  hl.dsp.exec_cmd("playerctl next"),       { locked = true })
hl.bind("XF86AudioPrev",  hl.dsp.exec_cmd("playerctl previous"),   { locked = true })
hl.bind("XF86AudioPlay",  hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })
hl.bind("XF86AudioPause", hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })

--------------------
---- ウィンドウルール ----
--------------------
hl.window_rule({
    name  = "suppress-maximize-events",
    match = { class = ".*" },
    suppress_event = "maximize",
})

hl.window_rule({
    -- XWayland のドラッグ不具合対策
    name  = "fix-xwayland-drags",
    match = {
        class = "^$", title = "^$",
        xwayland = true, float = true, fullscreen = false, pin = false,
    },
    no_focus = true,
})
LUAEOF

  # ── スクリーンショット ──
  # 【注意】ここは << 'LUAEOF' ではなく展開ありの heredoc。$HOME を
  # インストール先のユーザー名に依存させないため、Lua 側で os.getenv を使う。
  cat >> "$cfg" << 'LUAEOF'

--------------------
---- スクリーンショット ----
--------------------
local screenshot = os.getenv("HOME") .. "/.local/bin/screenshot.sh"
hl.bind("Print",         hl.dsp.exec_cmd(screenshot .. " area"))
hl.bind("SHIFT + Print", hl.dsp.exec_cmd(screenshot .. " screen"))
LUAEOF

  print_ok "Hyprland: Lua 設定の基本部分を生成しました"
}

# ============================================
# ユーティリティ: hyprland.lua に環境固有の設定を追記
# 引数1: 壁紙の絶対パス（空なら背景色で代替）
# ============================================
# ロケール・IME・キーボード・壁紙・自動起動といった「インストールのたびに
# 変わる要素」だけをここで足す。基本部分は write_hyprland_lua_base、または
# dotfiles リポジトリの hyprland.lua が担当する。
#
# 【重要】各ブロックは追記前に既存の記述を grep で確認すること。
# dotfiles 側の hyprland.lua が既に同じ設定を持っている場合に二重に書くと、
# Hyprland は後勝ちで解釈するため、ユーザーが意図した設定を黙って奪ってしまう。
# hyprlang 側の _conf_append_once と同じ考え方。
append_hyprland_lua_local() {
  local wallpaper="${1:-}"
  local cfg="${SKEL_ROOT}/.config/hypr/hyprland.lua"
  [[ -f "$cfg" ]] || return 0

  # ── 日本語ロケール ──
  # これが無いと fontconfig がフォールバックで中国語字形(SC)を選び、
  # ターミナル等の漢字が「変な字形」になる。
  if [[ "${CONFIG[japanese_env]}" == "yes" ]] && ! grep -qF 'hl.env("LANG"' "$cfg"; then
    local jp_locale="${CONFIG[locale]:-ja_JP.UTF-8}"
    {
      printf '\n-- 日本語ロケール（漢字が中国語字形になるのを防ぐ）\n'
      printf 'hl.env("LANG", "%s")\n' "$jp_locale"
      printf 'hl.env("LC_CTYPE", "%s")\n' "$jp_locale"
    } >> "$cfg"
  fi

  # ── キーボードレイアウト（jp106 固定）──
  # 既に kb_layout があるなら触らない。input セクションを二重に書くと後勝ちで
  # 上書きされ、ユーザーのトラックパッド設定などが消える。
  if ! grep -qF 'kb_layout' "$cfg"; then
  cat >> "$cfg" << 'LUAEOF'

--------------------
---- 入力 ----
--------------------
hl.config({
    input = {
        kb_layout    = "jp",
        kb_model     = "jp106",
        follow_mouse = 1,
        sensitivity  = 0,
        touchpad = {
            natural_scroll = false,
        },
    },
})
LUAEOF
  else
    print_ok "Hyprland: 既存のキーボード設定を尊重します（jp 設定の追記なし）"
  fi

  # ── 背景（壁紙が用意できなかった場合のみ）──
  # 【重要】disable_hyprland_logo = true にしているため、ここで何も指定しないと
  # hyprpaper が動かないときに完全な黒画面になる。
  if [[ -z "$wallpaper" ]] && ! grep -qF 'background_color' "$cfg"; then
    cat >> "$cfg" << 'LUAEOF'

-- 壁紙画像を取得できなかったため、背景を Esca のテーマ色で塗る
hl.config({
    misc = {
        background_color = 0x0d182c,
    },
})
LUAEOF
  fi

  # ── 自動起動 ──
  # 【重要】hyprlang の exec-once に相当するのは hl.on("hyprland.start", ...)。
  # hl.on は同じイベントに複数登録できるため、dotfiles 側に既に
  # hl.on("hyprland.start", ...) があっても、こちらを足して問題ない。
  # ただし同じコマンドを二重に起動すると waybar が2本立つなどの実害が出るので、
  # 「まだ書かれていないものだけ」を集めてから追記する。
  local autostart=()
  # 【重要】hl.exec_cmd の引数に `sh -c '...'` を入れ子にしないこと。
  # 公式の example/hyprland.lua は
  #     hl.exec_cmd("waybar & hyprpaper & firefox")
  # のように「素のシェル文字列」を渡す形しか示していない。
  # exec_cmd 側が既にシェル経由で実行するため、さらに sh -c で包むと
  # 引用符が二重になり、Hyprland のコマンド分割で壊れて何も起動しないことがある。
  # シェル演算子（&& や &）はそのまま書いてよい。
  #
  # waybar を少し待ってから起動するのは、hyprland.start と同時だと
  # pipewire-pulse やシート初期化が間に合わず、cava モジュールが即死して
  # バーから消える等の不安定さが出るため。
  #
  # 【重要】hl.dsp.exec_cmd（キーバインド）と hl.exec_cmd（自動起動）を区別すること。
  # 基本設定には SUPER+B の waybar トグルが hl.dsp.exec_cmd で入っているため、
  # `exec_cmd` だけで判定するとそれに誤反応し、自動起動が永久に追記されない。
  grep -qE 'hl\.exec_cmd\([^)]*waybar' "$cfg" \
    || autostart+=('    hl.exec_cmd("sleep 1 && waybar")')
  grep -qF 'nm-applet'          "$cfg" || autostart+=('    hl.exec_cmd("nm-applet --indicator")')
  grep -qF 'authentication-agent' "$cfg" || \
    autostart+=('    hl.exec_cmd("/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1")')
  if [[ -n "$wallpaper" ]]; then
    grep -qF 'hyprpaper' "$cfg" || autostart+=('    hl.exec_cmd("hyprpaper")')
  fi
  if [[ "${CONFIG[jp_ime]:-none}" =~ ^fcitx5 ]]; then
    # -r（replace）で既存プロセスを置き換え、環境変数の取りこぼしを防ぐ
    grep -qF 'fcitx5' "$cfg" || autostart+=('    hl.exec_cmd("fcitx5 -d -r")')
  elif [[ "${CONFIG[jp_ime]:-none}" =~ ^ibus ]]; then
    grep -qF 'ibus-daemon' "$cfg" || autostart+=('    hl.exec_cmd("ibus-daemon -drx")')
  fi

  # 【重要】追記するものが無いときに空の hl.on を書かないこと。
  # 中身のないハンドラが増えるだけで、設定を読む人を混乱させる。
  if [[ ${#autostart[@]} -gt 0 ]]; then
    {
      printf '\n--------------------\n---- 自動起動（インストーラが追加）----\n--------------------\n'
      printf 'hl.on("hyprland.start", function()\n'
      printf '%s\n' "${autostart[@]}"
      printf 'end)\n'
    } >> "$cfg"
  fi

  print_ok "Hyprland: Lua 設定に環境固有の項目を追記しました"
}
# ============================================
# ユーティリティ: 電源メニューを生成
# 引数1: WM 名（hyprland / niri）
# ============================================
# Waybar の電源ボタンから開くメニュー。fuzzel のリスト表示で実装する。
#
# 【経緯】以前は wlogout（大きなタイル状の全画面メニュー）を AUR からビルドして
# 使っていたが、次の理由で取りやめた。
#   ・AUR ビルドのため失敗しうる。失敗すると電源ボタンが無反応になる
#   ・背景クリックで閉じるのに --margin での余白調整が必須という癖がある
#   ・アイコンやスタイルの調整点が多く、fuzzel 版と二重メンテになっていた
# fuzzel は Hyprland / Niri のどちらでも既に導入済みで、追加依存も無い。
#
# 【重要】必ず write_waybar_config の「後」に呼ぶこと。
# write_waybar_config は引き継ぎ元の ~/.config/waybar/ を丸ごと複製するため、
# 先に呼ぶとここで書いたスクリプトが上書きされて消える。
write_power_menu() {
  local wm="$1"

  # ロック・ログアウトは WM ごとにコマンドが違う
  local lock_cmd logout_cmd
  case "$wm" in
    hyprland) lock_cmd="hyprlock";   logout_cmd="hyprctl dispatch exit" ;;
    *)        lock_cmd="swaylock -f"; logout_cmd="niri msg action quit --skip-confirmation" ;;
  esac

  local toggle_body
  toggle_body=$(cat << EOF
#!/usr/bin/env bash
# 電源メニュー（Waybar の電源ボタンから呼ばれる）

# 既に開いていれば閉じる（トグル動作）
if pgrep -x fuzzel > /dev/null 2>&1; then
  pkill -x fuzzel
  exit 0
fi

# 【重要】fuzzel が無い環境でも無反応にしないこと。
# 電源ボタンを押して何も起きないと、原因が極めて分かりにくい。
if ! command -v fuzzel > /dev/null 2>&1; then
  command -v notify-send > /dev/null 2>&1 && \\
    notify-send "電源メニュー" "fuzzel が見つかりません"
  exit 1
fi

# Waybar の電源ボタン直下（右上）にドロップダウン風に表示する
choice=\$(printf '%s\n' \\
  "ロック" \\
  "ログアウト" \\
  "サスペンド" \\
  "再起動" \\
  "電源を切る" \\
  | fuzzel --dmenu --prompt "⏻  " \\
      --anchor=top-right --x-margin=16 --y-margin=38 \\
      --lines=5 --width=18 2>/dev/null) || exit 0

case "\$choice" in
  "ロック")       ${lock_cmd} ;;
  "ログアウト")   ${logout_cmd} ;;
  "サスペンド")   systemctl suspend ;;
  "再起動")       systemctl reboot ;;
  "電源を切る")   systemctl poweroff ;;
esac
EOF
)

  mkdir -p "${SKEL_ROOT}/.config/waybar/scripts"

  # 本スクリプトが生成する既定 Waybar 設定が参照するパス。ここは常に上書きする。
  printf '%s\n' "$toggle_body" > "${SKEL_ROOT}/.config/waybar/power_menu.sh"
  chmod +x "${SKEL_ROOT}/.config/waybar/power_menu.sh"

  # 【重要】引き継ぎ元が scripts/power_menu_toggle.sh を持っている場合は
  # 上書きしないこと。dotfiles 側のスクリプトのほうが作り込まれている
  # （WM を実行時に判定する、独自の選択肢を持つ等）ことが多く、
  # ここで潰すと「リポジトリを直しても反映されない」状態になる。
  local host_toggle="${SKEL_ROOT}/.config/waybar/scripts/power_menu_toggle.sh"
  if [[ -f "$host_toggle" ]]; then
    chmod +x "$host_toggle"
    print_ok "電源メニュー: 引き継ぎ元の power_menu_toggle.sh を尊重します"
  else
    printf '%s\n' "$toggle_body" > "$host_toggle"
    chmod +x "$host_toggle"
    print_ok "電源メニュー: fuzzel 版を設定しました"
  fi
}

write_waybar_config() {
  local wm="$1"
  local tz="${CONFIG[timezone]:-Asia/Tokyo}"

  # dry_run 時は /mnt がマウントされていないためスキップ
  if [[ "${CONFIG[dry_run]}" == "yes" ]]; then
    print_warn "ドライランのため Waybar 設定生成をスキップします (${wm})"
    return 0
  fi

  local dest_dir="${SKEL_ROOT}/.config/waybar"
  mkdir -p "$dest_dir"

  # ホストPCの ~/.config/waybar/ が存在する場合、その設定とカスタムスクリプトをコピーする
  local host_home
  host_home=$(_host_home)
  local host_waybar_dir=""
  [[ -n "$host_home" ]] && host_waybar_dir="${host_home}/.config/waybar"

  # ホストPCの ~/.config/waybar/ が存在する場合は自動でコピーする
  if [[ -d "$host_waybar_dir" ]]; then
    run_cmd "ホストPCからWaybar設定をコピー" cp -a "$host_waybar_dir/." "$dest_dir/"

    # 0-a. 編集中に生まれたバックアップファイルを除去する。
    # テーマを試したときの config.jsonc.bak_cyberpunk / style.css.antigravity_bak
    # のような残骸がそのまま新環境に入ると、どれが本番か分からなくなる。
    # waybar 自身は読まないので実害はないが、混乱の元なので配布前に落とす。
    run_cmd_soft "Waybar 設定のバックアップファイルを除去" \
      find "$dest_dir" -type f \( -name '*.bak' -o -name '*.bak_*' -o -name '*_bak' \) -delete || true

    # 0-b. 実行権の保証（重要）
    # cp -a はホスト側のパーミッションをそのまま持ち込む。ホストの *.sh から
    # 実行権が落ちていると（例: ブラウザ経由でDLしたファイルで置き換えた場合）、
    # waybar の custom モジュールは exec の出力がゼロになり「モジュールごと消える」。
    # 原因が非常に分かりにくいので、ここで必ず実行権を付け直す。
    # 【重要】-maxdepth を付けないこと。実際のスクリプトは scripts/ 配下にあり、
    # 直下だけを見ると全部取りこぼす。.py も exec から直接呼ばれるので対象に含める。
    # 【重要】拡張子で判定しきれない。scripts/rofi-power-menu のように拡張子なしで
    # 直接実行されるスクリプトがあり（power_menu_toggle.sh が -modi で参照する）、
    # ここを取りこぼすと電源メニューだけが無反応になる。シバンの有無でも拾う。
    run_cmd_soft "Waybar スクリプトに実行権を付与" \
      bash -c 'd="$1"
        find "$d" -type f \( -name "*.sh" -o -name "*.py" \) -exec chmod +x {} + || true
        find "$d" -type f ! -perm -u+x -print0 | while IFS= read -r -d "" f; do
          if [ "$(head -c 2 "$f" 2>/dev/null)" = "#!" ]; then chmod +x "$f"; fi
        done
        true' _ "$dest_dir" || true

    # 1. ハードコードされたユーザー絶対パスを $HOME に置換する。
    # 【重要】config.jsonc だけでなく scripts/ 配下も対象にする。ホストでは
    # "$HOME/..." 表記と "/home/<user>/..." 表記が混在していることがあり、
    # 後者を残すとインストール先のユーザー名では存在しないパスになって黙って壊れる。
    # 【重要】ユーザー名を basename で決め打ちしないこと。
    # _host_home() は ~/dotfiles を優先して返すため、basename は "dotfiles" に
    # なりうる。その場合 s|/home/dotfiles/...| は何にもマッチせず、ホスト側の
    # 絶対パスが黙って残る。/home/<任意> にマッチする汎用パターンで置換する。
    run_cmd_soft "Waybar 設定の絶対パスを \$HOME へ書き換え" \
      find "$dest_dir" -type f \( -name '*.jsonc' -o -name '*.json' -o -name '*.sh' -o -name '*.py' -o -name '*.xml' \) \
        -exec sed -i "s|/home/[^/\"' ]*/\.config/waybar/|\$HOME/.config/waybar/|g" {} + || true

    # 2. config.jsonc: WM に応じたワークスペース・ウィンドウモジュールの書き換え
    if [[ -f "$dest_dir/config.jsonc" ]] && [[ "$wm" == "hyprland" ]]; then
      sed -i 's/niri\/workspaces/hyprland\/workspaces/g' "$dest_dir/config.jsonc"
      sed -i 's/niri\/window/hyprland\/window/g' "$dest_dir/config.jsonc"
      # hyprland/workspaces のオプションを追加
      sed -i 's/"hyprland\/workspaces": {/"hyprland\/workspaces": {\n        "disable-scroll": true,\n        "all-outputs": true,/g' "$dest_dir/config.jsonc"
    fi

    # 3. style.css: ハードコードされたアイコン絶対パスを相対パスに置換
    if [[ -f "$dest_dir/style.css" ]]; then
      sed -i "s|/home/[^/\"' ]*/\.config/waybar/||g" "$dest_dir/style.css"

      # アクティブなクラス名をWMごとに調整
      local active_class="focused"
      [[ "$wm" == "hyprland" || "$wm" == "niri" ]] && active_class="active"
      if [[ "$active_class" != "focused" ]]; then
        sed -i "s/button.focused/button.${active_class}/g" "$dest_dir/style.css"
      fi
    fi

    # 4. ロック・ログアウトの WM 差異を吸収する（niri 用の記述 → hyprland 用）。
    #
    # 【重要】スクリプト自身が WM を判定している場合は書き換えないこと。
    # 判定つきスクリプトは niri 用と Hyprland 用の分岐を両方持っているため、
    # 一律に sed をかけると niri 側の分岐まで hyprctl に化けて、
    # 「niri でログアウトできない設定」を作り込んでしまう。
    # 判定の有無は hyprctl / hyprlock を既に参照しているかで見分ける
    # （grep -L = そのパターンを含まないファイルだけを対象にする）。
    if [[ "$wm" == "hyprland" ]]; then
      run_cmd_soft "Waybar スクリプトのログアウト処理を Hyprland 用に調整" \
        bash -c 'd="$1"
          find "$d" -type f \( -name "*.sh" -o -name "*.py" \) -print0 \
            | xargs -0 -r grep -L -- "hyprctl" \
            | xargs -r sed -i "s/niri msg action quit --skip-confirmation/hyprctl dispatch exit/g"
          true' _ "$dest_dir" || true

      # 【重要】ロックコマンドも WM で異なる。Hyprland には hyprlock を入れており
      # swaylock は入らないため、swaylock 決め打ちのスクリプトは電源メニューの
      # 「画面ロック」が無反応になる。ここも判定つきスクリプトは除外する。
      run_cmd_soft "Waybar スクリプトのロック処理を Hyprland 用に調整" \
        bash -c 'd="$1"
          find "$d" -type f \( -name "*.sh" -o -name "*.py" \) -print0 \
            | xargs -0 -r grep -L -- "hyprlock" \
            | xargs -r sed -i "s/\bswaylock\b/hyprlock/g"
          true' _ "$dest_dir" || true

      # 【重要】壁紙デーモンも異なる（niri: swaybg / Hyprland: hyprpaper）。
      # swaybg は Hyprland 側の pkgs に無いため、swaybg 決め打ちのスクリプトは
      # 壁紙が変わらないまま無言で終わる。ただし swaybg と hyprpaper は
      # 起動方法も切り替え方法も違い、単純な文字列置換では対応できない。
      # 変換はせず、検出して知らせるだけにする（スクリプト側での対応を促す）。
      if find "$dest_dir" -type f -name '*.sh' -print0 \
           | xargs -0 -r grep -l -- 'swaybg' \
           | xargs -r grep -L -- 'hyprpaper' | grep -q .; then
        print_warn "Waybar: swaybg 前提のスクリプトがあります。Hyprland では hyprpaper を使うため壁紙が変わりません。hyprpaper にも対応したスクリプトへの差し替えを推奨します。"
      fi
    fi

    # 5. Nerd Fonts v3 で削除されたアイコンの置換。
    # 【重要】Nerd Fonts 3.0 で Material Design Icons が U+F500〜U+FD46 から
    # U+F0001〜 へ移動し、旧コードポイントは削除された。
    # 現在の ttf-hack-nerd / ttf-jetbrains-mono-nerd は v3 なので、
    # 旧コードポイントを書いた設定はフォントが正しく入っていても豆腐(□)になる。
    # ここでは Font Awesome 範囲(U+F500 未満・v3 でも不変)の同義グリフへ寄せる。
    # ※ 5桁の新コードポイント(U+F0001〜)はそのままで正しいので触らない。
    run_cmd_soft "Waybar アイコンを Nerd Fonts v3 対応に置換" bash -c "
      f='$dest_dir/config.jsonc'
      [ -f \"\$f\" ] || exit 0
      # 音符（ラジオ）: 旧 nf-mdi-radio → nf-fa-music
      sed -i 's/\xef\xa3\x97/\xef\x80\x81/g' \"\$f\"
      # 稲妻（充電中）: 旧 nf-mdi-flash → nf-fa-bolt
      sed -i 's/\xef\x97\xa7/\xef\x83\xa7/g' \"\$f\"
      # 温度計: 旧 nf-mdi-thermometer → nf-fa-thermometer_half
      sed -i 's/\xef\x9d\xa9/\xef\x8b\x89/g' \"\$f\"
      sed -i 's/\xef\x9d\xab/\xef\x8b\x89/g' \"\$f\"
      # 有線ネットワーク: 旧 nf-mdi-ethernet → nf-fa-sitemap
      sed -i 's/\xef\x9e\x96/\xef\x83\xa8/g' \"\$f\"
    " || true

    # 6. 壁紙パスの修正。
    # 引き継ぎ元の scripts/wallpaper は /usr/share/hypr/wall1.png のような
    # ホストPC 固有の絶対パスを指しており、新環境にそのファイルは存在しない。
    # 実行しても壁紙が変わらない（黒いまま）ので、配置先へ向け直す。
    run_cmd_soft "Waybar スクリプトの壁紙パスを調整" \
      find "$dest_dir" -type f \( -name 'wallpaper' -o -name '*.sh' \) \
        -exec sed -i "s|/usr/share/hypr/wall[0-9]*\.png|${WALLPAPER_DEST}|g" {} + || true

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

  # ワークスペースのラベル書式。
  # 【重要】niri で "{name}" を使ってはいけない。niri の {name} は
  # 「名前付きワークスペースの名前」しか返さず、名前なし（既定）では空文字になり、
  # ラベルのない四角いボタンが並ぶだけになる。
  # {value} なら「名前、無ければインデックス」を返す（niri モジュールの既定値）。
  local ws_format
  case "$wm" in
    niri) ws_format="{value}" ;;
    *)    ws_format="{name}" ;;
  esac

  # Nerd Font のアイコンは私用領域(U+E000-F8FF)の文字。
  # 【重要】スクリプト本文に直接書くと、ファイルの受け渡し経路で欠落することがある。
  # 実際にこのスクリプトでも全アイコンが空文字に化けていて、
  # waybar に "40%" のように数値だけが並ぶ状態になっていた。
  # 本文は ASCII のみに保ち、書き出し時に printf で実体化する。
  local ico_vol ico_mute ico_chg ico_plug
  local ico_bat0 ico_bat1 ico_bat2 ico_bat3 ico_bat4
  ico_vol=$(_nf f028)  # 音量
  ico_mute=$(_nf f026)  # ミュート
  ico_chg=$(_nf f0e7)  # 充電中
  ico_plug=$(_nf f1e6)  # 電源接続
  ico_bat0=$(_nf f244)  # 電池 空
  ico_bat1=$(_nf f243)
  ico_bat2=$(_nf f242)
  ico_bat3=$(_nf f241)
  ico_bat4=$(_nf f240)  # 電池 満
  local ico_menu ico_ff ico_files ico_term ico_power
  local ico_cpu ico_mem ico_wifi ico_eth ico_nonet
  ico_menu=$(_nf f009)  # アプリメニュー
  ico_ff=$(_nf f269)  # Firefox
  ico_files=$(_nf f07b)  # ファイル
  ico_term=$(_nf f120)  # 端末
  ico_power=$(_nf f011)  # 電源
  ico_cpu=$(_nf f2db)  # CPU
  ico_mem=$(_nf f1c0)  # メモリ
  ico_wifi=$(_nf f1eb)  # 無線
  ico_eth=$(_nf f0e8)  # 有線
  ico_nonet=$(_nf f127)  # 未接続

  # 端末とロック・ログアウトは WM ごとに異なる
  local term_cmd lock_cmd logout_cmd
  case "$wm" in
    hyprland) term_cmd="kitty";     lock_cmd="hyprlock";  logout_cmd="hyprctl dispatch exit" ;;
    *)        term_cmd="alacritty"; lock_cmd="swaylock -f"; logout_cmd="niri msg action quit --skip-confirmation" ;;
  esac

  # ワークスペースボタンのアクティブ CSS クラス名（WM ごとに異なる）
  local active_class
  case "$wm" in
    hyprland|niri) active_class="active" ;;
    *)             active_class="focused" ;;
  esac

  mkdir -p ${SKEL_ROOT}/.config/waybar

  # modules-left を構築（trailing comma なしの正しい JSON）
  local modules_left_json="        \"${ws_module}\""
  if [[ ${#extra_left_modules[@]} -gt 0 ]]; then
    modules_left_json=""
    for mod in "${extra_left_modules[@]}"; do
      modules_left_json+="        \"${mod}\","$'\n'
    done
    modules_left_json+="        \"${ws_module}\""
  fi

  cat > ${SKEL_ROOT}/.config/waybar/config.jsonc << EOF
{
    "layer": "top",
    "position": "top",
    "height": 44,
    "spacing": 4,
    "modules-left": [
        "custom/menu",
${modules_left_json},
        "custom/firefox",
        "custom/files",
        "custom/terminal"
    ],
    "modules-center": [
        "clock"
    ],
    "modules-right": [
        "custom/cava",
        "custom/radio",
        "cpu",
        "memory",
        "network",
        "pulseaudio",
        "battery",
        "tray",
        "custom/power"
    ],
    "custom/menu": {
        "format": "${ico_menu}",
        "tooltip": false,
        "on-click": "fuzzel"
    },
    "custom/firefox": {
        "format": "${ico_ff}",
        "tooltip": false,
        "on-click": "firefox"
    },
    "custom/files": {
        "format": "${ico_files}",
        "tooltip": false,
        "on-click": "nautilus"
    },
    "custom/terminal": {
        "format": "${ico_term}",
        "tooltip": false,
        "on-click": "${term_cmd}"
    },
    "custom/cava": {
        "exec": "\$HOME/.config/waybar/cava.sh",
        "tooltip": false,
        "restart-interval": 30
    },
    "custom/radio": {
        "exec": "\$HOME/.config/waybar/radio.sh status",
        "interval": 5,
        "tooltip": false,
        "on-click": "\$HOME/.config/waybar/radio.sh toggle"
    },
    "custom/power": {
        "format": "${ico_power}",
        "tooltip": false,
        "on-click": "\$HOME/.config/waybar/power_menu.sh"
    },
    "cpu": {
        "format": "${ico_cpu} {usage}%",
        "interval": 5
    },
    "memory": {
        "format": "${ico_mem} {percentage}%",
        "interval": 5
    },
    "network": {
        "format-wifi": "${ico_wifi} {signalStrength}%",
        "format-ethernet": "${ico_eth}",
        "format-disconnected": "${ico_nonet}",
        "tooltip-format": "{ifname} {ipaddr}",
        "on-click": "nm-connection-editor"
    },
    "${ws_module}": {
        ${ws_options}
        "format": "${ws_format}"
    },
    "clock": {
        "timezone": "${tz}",
        "tooltip-format": "<big>{:%Y %B}</big>\n<tt><small>{calendar}</small></tt>",
        "format": "{:%Y-%m-%d %H:%M:%S}",
        "interval": 1
    },
    "pulseaudio": {
        "format": "${ico_vol} {volume}%",
        "format-muted": "${ico_mute} Muted",
        "on-click": "pavucontrol"
    },
    "battery": {
        "states": {
            "warning": 30,
            "critical": 15
        },
        "format": "{icon} {capacity}%",
        "format-charging": "${ico_chg} {capacity}%",
        "format-plugged": "${ico_plug} {capacity}%",
        "format-icons": ["${ico_bat0}", "${ico_bat1}", "${ico_bat2}", "${ico_bat3}", "${ico_bat4}"]
    },
    "tray": {
        "icon-size": 18,
        "spacing": 10
    }
}
EOF

  # ── cava（オーディオビジュアライザ）──
  # 【重要】waybar の "cava" 内蔵モジュールは使えない。
  # Arch の公式 waybar は -Dlibcava=disabled でビルドされており、
  # モジュール自体が存在しないため書いても無視される。
  # そこで cava コマンドを raw 出力モードで回し、custom モジュールに流す。
  cat > ${SKEL_ROOT}/.config/waybar/cava.conf << 'CVEOF'
# waybar 用の cava 設定（通常の cava の見た目には影響しない）
# バーの本数を変えたい場合は bars を編集する。
[general]
bars = 12
framerate = 20

[input]
method = pulse
source = auto

[output]
# waybar へ数値を流すための設定。
# ascii_max_range = 7 にすると各バーが 0-7 の1桁になり、
# bar_delimiter = 0（区切りなし）でも桁が混ざらない。
method = raw
raw_target = /dev/stdout
data_format = ascii
ascii_max_range = 7
bar_delimiter = 0
CVEOF

  cat > ${SKEL_ROOT}/.config/waybar/cava.sh << 'CSEOF'
#!/usr/bin/env bash
# cava の出力を waybar 用のブロック文字に変換して流し続ける。
#
# waybar の custom モジュールは interval を指定しない場合、
# スクリプトの標準出力を1行ずつ読み続ける（連続モード）。
#
# 【重要】ブロック文字(U+2581-2588)をスクリプトに直接書かない。
# ファイルの受け渡し経路で非ASCII文字が失われる事故があったため、
# UTF-8 のバイト列から組み立てる。printf '\uXXXX' はロケール依存なので使わない。

command -v cava >/dev/null 2>&1 || exit 0

CONF="$HOME/.config/waybar/cava.conf"
[[ -f "$CONF" ]] || exit 0

# U+2581(▁) から U+2588(█) の8段階を作る
bars=()
for i in 0 1 2 3 4 5 6 7; do
  bars+=("$(printf '%b' "\\xe2\\x96\\x$(printf %x $((0x81 + i)))")")
done

# sed を1回起動してストリーム変換する。
# bash のループで1文字ずつ処理すると 20fps x 12本 で CPU を食うため避ける。
# -u は行バッファリング無効（付けないと waybar に届くのが遅れる）
exec cava -p "$CONF" 2>/dev/null | sed -u \
  -e "s/0/${bars[0]}/g" -e "s/1/${bars[1]}/g" \
  -e "s/2/${bars[2]}/g" -e "s/3/${bars[3]}/g" \
  -e "s/4/${bars[4]}/g" -e "s/5/${bars[5]}/g" \
  -e "s/6/${bars[6]}/g" -e "s/7/${bars[7]}/g"
CSEOF

  # ── 電源メニュー ──
  # 【重要】ここでは生成しない。power_menu.sh は write_power_menu が
  # 同じパスへ書き出す。write_waybar_config → write_power_menu の順で
  # 必ず呼ばれるため、ここで作っても即座に上書きされて一度も使われない。
  # chmod も write_power_menu 側で行う。

  # ── ラジオ局リスト（自由に編集できるよう別ファイルにする）──
  # SomaFM の公式ページに記載された直接URL。局を足すには行を追加するだけ。
  cat > ${SKEL_ROOT}/.config/waybar/stations.conf << 'STEOF'
# 表示名|ストリームURL
# 行頭の # はコメント。局を追加・変更する場合はこのファイルを編集する。
Groove Salad|https://ice.somafm.com/groovesalad
Drone Zone|https://ice.somafm.com/dronezone
Indie Pop|https://ice.somafm.com/indiepop
Deep Space One|https://ice.somafm.com/deepspaceone
Space Station|https://ice.somafm.com/spacestation
STEOF

  # ── ラジオ ──
  cat > ${SKEL_ROOT}/.config/waybar/radio.sh << 'RDEOF'
#!/usr/bin/env bash
# waybar のラジオモジュール。
#
# 【重要】waybar の custom モジュールは exec の出力が空だと
# モジュールごと画面から消える。原因が非常に分かりにくいので、
# どの経路を通っても必ず1行出力すること（set -e で落ちないよう注意）。

CONF="$HOME/.config/waybar/stations.conf"
PIDFILE="/tmp/waybar-radio-$UID.pid"
NAMEFILE="/tmp/waybar-radio-$UID.name"
# U+F001 (Nerd Font の音符) を UTF-8 バイトで直接指定する。
# printf '\uf001' はロケール依存で C ロケールだと文字列のまま出るため使わない。
ICON=$(printf '\xef\x80\x81')

_running() {
  [[ -f "$PIDFILE" ]] || return 1
  local pid; pid=$(cat "$PIDFILE" 2>/dev/null) || return 1
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

_stop() {
  if [[ -f "$PIDFILE" ]]; then
    kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null || true
    rm -f "$PIDFILE" "$NAMEFILE"
  fi
}

case "${1:-status}" in
  status)
    if _running; then
      echo "${ICON} $(cat "$NAMEFILE" 2>/dev/null || echo '再生中')"
    else
      echo "${ICON}"
    fi
    ;;

  toggle)
    if _running; then
      _stop
      exit 0
    fi
    [[ -f "$CONF" ]] || exit 0

    # コメントと空行を除いた局名を fuzzel に渡す
    sel=$(grep -v '^\s*#' "$CONF" | grep -v '^\s*$' | cut -d'|' -f1 \
          | fuzzel --dmenu --prompt "ラジオ: " 2>/dev/null) || exit 0
    [[ -n "$sel" ]] || exit 0

    url=$(grep -F "${sel}|" "$CONF" | head -n1 | cut -d'|' -f2-)
    [[ -n "$url" ]] || exit 0

    # --no-video: 音声のみ / --really-quiet: ログを出さない
    mpv --no-video --really-quiet "$url" >/dev/null 2>&1 &
    echo $! > "$PIDFILE"
    printf '%s' "$sel" > "$NAMEFILE"
    ;;
esac
exit 0
RDEOF

  # 【重要】power_menu.sh をここに含めないこと。
  # 上記のとおりこの関数では生成しなくなったため、まだファイルが存在しない。
  # set -e 下で存在しないファイルを chmod するとインストーラが止まる。
  # power_menu.sh の生成と chmod は write_power_menu が担当する。
  chmod +x ${SKEL_ROOT}/.config/waybar/radio.sh \
           ${SKEL_ROOT}/.config/waybar/cava.sh

  cat > ${SKEL_ROOT}/.config/waybar/style.css << EOF
#waybar {
    background-color: rgba(26, 27, 38, 0.95);
    border-bottom: 1px solid rgba(255, 255, 255, 0.1);
    color: #c0caf5;
    font-family: "JetBrainsMono Nerd Font", "Noto Sans CJK JP", sans-serif;
    /* Nerd Font のアイコングリフは文字枠内に小さめに描かれるため、
       13px だとアイコンが潰れて見づらい → 14px に合わせる */
    font-size: 14px;
}
#workspaces button {
    padding: 0 7px;
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
/* アイコンを含むモジュールはさらに一段大きくして視認性を確保 */
#pulseaudio, #battery {
    font-size: 16px;
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

  # STEP_TOTAL に計上済みのため、スキップ時もステップ表示を先に行う
  # （早期 return より前に print_step しないと [n/N] の番号がずれる）
  print_step "デスクトップ環境のインストール: ${CONFIG[desktop]}"

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

  # 音声・Bluetooth・ファイルシステム・マルチメディア・ブラウザなどのデスクトップ共通パッケージ
  local desktop_common_pkgs=(
    pipewire pipewire-pulse wireplumber
    pipewire-alsa pipewire-jack libldac
    bluez bluez-utils
    cups cups-pdf avahi nss-mdns system-config-printer
    xdg-user-dirs xdg-utils
    firefox
    # ファイルシステムツール（ntfs-3g / exfatprogs 等）は do_pacstrap で導入済み。
    # ここには GUI 側だけを置く。
    #
    # 【重要】スマートフォン接続は Android と iPhone で必要なものが異なる。
    # ・Android は MTP を使うので gvfs-mtp でよい。
    # ・iPhone は MTP を話さず、Apple 独自の AFC と PTP を使う。
    #   写真・動画は gvfs-gphoto2 (PTP)、アプリのドキュメント領域は
    #   gvfs-afc が担当するので、両方入れないと中身が見えない。
    # 以前は gvfs-mtp しか無く、iPhone を挿しても何も表示されなかった。
    #
    # gvfs-afc は libimobiledevice と usbmuxd を依存に持つため、
    # この2つは自動で入る（明示指定は不要）。
    # ifuse は公式リポジトリでの提供状況が変わりうるので、ここには含めない。
    # gvfs 経由でファイルマネージャから開ければ通常の用途は足りる。
    gvfs gvfs-mtp gvfs-smb gvfs-afc gvfs-gphoto2
    gnome-disk-utility udisks2
    gst-plugins-good gst-libav
    libdvdcss libdvdread libdvdnav
    # 【重要】mpv は DE を問わずここで入れること。
    # 以前は Hyprland / Niri の pkgs にしか入れておらず、GNOME・KDE・Xfce・
    # Budgie・COSMIC には動画プレイヤーが一つも入らない状態だった。
    # 一方でコーデック(gst-libav / libdvd*)は全DEに入れており、
    # さらに do_desktop 末尾で ~/.config/mpv を全DEの skel に複製している。
    # 「設定だけあって本体が無い」ちぐはぐな状態になるため共通側に置く。
    mpv
    # streamlink / yt-dlp / sox / imagemagick / qrencode は do_pacstrap へ移動。
    # desktop=none（CLI のみ）でも入るようにするため。
    # ここに書き戻すと、その構成にだけ入らない状態に逆戻りする。
  )

  # ── ホストPC の Waybar 設定が必要とするコマンド（Hyprland / Niri 用）──
  # write_waybar_config はホストPC の ~/.config/waybar/ をそのまま持ち込む。
  # その config.jsonc / scripts/*.sh が呼ぶコマンドが入っていないと、
  # モジュールは表示されるのにクリックしても何も起きない（原因が分かりにくい）ため、
  # 依存コマンドを WM 本体と同じトランザクションでまとめて導入する。
  #   rofi      : 汎用ランチャー。電源メニューは fuzzel 版のため必須ではないが、
  #               ホストの ~/.config/rofi/*.rasi をそのまま複製しており、
  #               他のスクリプトから呼びたくなったときに動くよう残している。
  #   ranger    : ファイルマネージャモジュール（alacritty -e ranger）
  #   playerctl : custom/media（再生中タイトル表示・再生停止）
  #   psmisc    : killall（nautilus/firefox のトグル起動）
  #   zenity    : scripts/radiostation.sh の局選択ダイアログ、
  #               scripts/wallchange.sh の壁紙選択ダイアログ。
  #               【重要】これが無いと「アイコンは出るのに中クリックが無反応」に
  #               なる。どちらのスクリプトも `|| exit 1` で静かに終わるため
  #               エラーすら出ず、原因の切り分けが非常に難しい。
  #   mpv-mpris : custom/media が曲名を表示するのに必須。  #               【重要】mpv は既定では MPRIS を喋らないため、playerctl だけ
  #               入れても再生中の情報を取得できない。取得できないと exec の
  #               出力が空になり、custom モジュールごとバーから消える
  #               （「ラジオの音は出るのに曲名が出ない」状態になる）。
  #               パッケージが /etc/mpv/scripts/mpris.so に置いてくれるため、
  #               mpv が全ユーザー向けに自動読み込みする。追加設定は不要。
  # ※ python は ranger の依存で入るため明示不要（get_weather.py / waybar_cava.py 用）。
  # ※ config.jsonc から参照されていないスクリプト（mms.sh の yt-dlp/pv、
  #    server.sh の gum）の依存はここには入れない。使う場合は手動で導入すること。
  #   alsa-utils: wireplumber モジュールの右クリック（alacritty -e alsamixer）。
  #               これが無いと端末が一瞬開いて即閉じる。
  local host_waybar_deps=(rofi ranger playerctl psmisc zenity mpv-mpris alsa-utils)

  # ── トランザクション統合 ──
  # DM・gnome-keyring・推奨アプリをデスクトップ本体と同一の pacman 実行にまとめ、
  # 依存解決とフォントキャッシュ再生成などのフック実行の重複を減らす（時間短縮）
  case "${CONFIG[dm]:-none}" in
    sddm)           desktop_common_pkgs+=(sddm) ;;
    gdm)            desktop_common_pkgs+=(gdm) ;;
    lightdm)        desktop_common_pkgs+=(lightdm lightdm-gtk-greeter) ;;
    cosmic-greeter) desktop_common_pkgs+=(cosmic-greeter) ;;
    greetd)         desktop_common_pkgs+=(greetd greetd-tuigreet) ;;
  esac
  [[ "${CONFIG[desktop]}" == "gnome" ]] && desktop_common_pkgs+=(gnome-keyring)

  # 初心者向け推奨アプリ（unzip/git 等の軽量ツール。LibreOffice は選択制）
  desktop_common_pkgs+=(unzip p7zip wget curl git nano htop)
  # LibreOffice 本体 + 日本語言語パック(-ja)。本体だけだと UI が英語のままなので、
  # ロケールが日本語でも -ja を入れて初めて UI が日本語になる。
  if [[ "${CONFIG[install_office]:-no}" == "yes" ]]; then
    desktop_common_pkgs+=(libreoffice-fresh)
    [[ "${CONFIG[japanese_env]}" == "yes" ]] && desktop_common_pkgs+=(libreoffice-fresh-ja)
  fi
  [[ "${CONFIG[japanese_env]}" == "yes" ]] && desktop_common_pkgs+=(firefox-i18n-ja)

  case "${CONFIG[desktop]}" in
    kde)
      # 【重要】plasma-nm / plasma-pa / kscreen / bluedevil は plasma-desktop の
      # optional depend であって依存ではない。「最小」を選ぶと plasma-desktop しか
      # 入らないため、Wi-Fi を選ぶ GUI も音量アプレットも画面設定も無い状態になる。
      # 有線が無いノートでは、そこから復旧する手段が nmtui しか残らない。
      # plasma-meta（標準/フル）には含まれるので、--needed により重複は無害。
      local pkgs=(sddm-kcm konsole dolphin colord-kde
                  plasma-nm plasma-pa kscreen bluedevil)
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
        arch-chroot /mnt pacman -S --noconfirm --needed "${pkgs[@]}" "${desktop_common_pkgs[@]}"

      # 【重要】「フル」を選ぶと音量アイコンがパネルに2つ並ぶ。
      # kde-applications グループに含まれる kmix（旧来のミキサー）と、
      # plasma-meta に含まれる plasma-pa（Plasma 標準の音量アプレット）が
      # どちらもトレイに常駐するため。上流は「どちらかを削除せよ」という立場で、
      # 両者が共存する構成は KDE 側では想定されていない。
      #
      # ここでパッケージを消さないのは、利用者が「全部入り」を選んだ意思に
      # 反するのと、-Rns の巻き込み削除を避けるため（GNOME 側と同じ方針）。
      # XDG 仕様どおり ~/.config/autostart に同名ファイルを置いて Hidden で
      # 上書きすれば、kmix は残したまま自動起動だけを止められる。
      # 手動起動（メニューから kmix を選ぶ）は従来どおり可能。
      if [[ "${CONFIG[kde_apps]}" == "full" ]]; then
        run_cmd "KDE: kmix の自動起動を抑止（音量アイコン重複の回避）" bash -c "
          mkdir -p ${SKEL_ROOT}/.config/autostart
          cat > ${SKEL_ROOT}/.config/autostart/kmix_autostart.desktop << 'KMIXEOF'
[Desktop Entry]
Type=Application
Name=KMix
Exec=kmix
Hidden=true
X-GNOME-Autostart-enabled=false
KMIXEOF
        "
      fi
      ;;

    gnome)
      local pkgs=(gnome gnome-tweaks power-profiles-daemon)
      run_cmd_retry "GNOME インストール" \
        arch-chroot /mnt pacman -S --noconfirm --needed "${pkgs[@]}" "${desktop_common_pkgs[@]}"
      
      # 電源プロファイルデーモンの有効化
      run_cmd "power-profiles-daemon 有効化" systemctl --root=/mnt enable power-profiles-daemon

      # 初期セットアップウィザードのスキップ。
      # 【重要】pacman -Rns でパッケージごと消してはいけない。
      #   -s は「依存で入って今は不要になったパッケージ」を芋づる式に削除するため、
      #   gnome グループの構成によっては GNOME 側のコンポーネントを巻き込む。
      #   しかも run_cmd_soft + || true で失敗も削除結果も握り潰されるため、
      #   何が消えたかは /var/log/pacman.log を読むまで分からない。
      # gnome-initial-setup 自身が見る完了フラグを skel に置けば、
      # パッケージを触らずにウィザードだけを確実にスキップできる。
      run_cmd "GNOME 初期セットアップウィザードのスキップ設定" bash -c "
        mkdir -p ${SKEL_ROOT}/.config
        echo 'yes' > ${SKEL_ROOT}/.config/gnome-initial-setup-done
      "

      # gnome-keyring はデスクトップ本体と同一トランザクションで導入済み
      ;;

    xfce)
      # 【重要】blueman を明示すること。bluez と bluetooth.service は全DE共通で
      # 導入・有効化しているが、xfce4 / xfce4-goodies には Bluetooth の GUI が
      # 含まれない。無いと「Bluetooth は動いているのに繋ぐ画面が無い」状態になる。
      # ※ polkit 認証エージェント(polkit-gnome)は xfce4-session の依存として
      #    自動導入・自動起動されるため、ここで明示する必要はない。
      local pkgs=(xfce4 xfce4-goodies network-manager-applet blueman)
      run_cmd_retry "Xfce インストール" \
        arch-chroot /mnt pacman -S --noconfirm --needed "${pkgs[@]}" "${desktop_common_pkgs[@]}"
      ;;

    budgie)
      local pkgs=(budgie budgie-control-center nautilus gnome-console network-manager-applet gedit evince file-roller eog gnome-screenshot power-profiles-daemon brightnessctl)
      run_cmd_retry "Budgie インストール" \
        arch-chroot /mnt pacman -S --noconfirm --needed "${pkgs[@]}" "${desktop_common_pkgs[@]}"
      
      # 電源プロファイルデーモンの有効化（Budgie/GNOMEの電源管理に必須級）
      run_cmd "power-profiles-daemon 有効化" systemctl --root=/mnt enable power-profiles-daemon

      # 照度スライダーがキーボードを押すまで表示されないバグの回避策
      # ログイン時に brightnessctl でダミーのイベントを発生させる
      run_cmd "Budgie 照度スライダー回避スクリプト追加" bash -c "
        mkdir -p ${SKEL_ROOT}/.config/autostart
        cat > ${SKEL_ROOT}/.config/autostart/brightness-fix.desktop << 'EOF'
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
        arch-chroot /mnt pacman -S --noconfirm --needed "${pkgs[@]}" "${desktop_common_pkgs[@]}"
      # COSMIC のシェル(cosmic-text)は /etc/fonts/conf.d の locale ルールを読まず、
      # 既定フォント（Open Sans / Noto Sans Mono）に日本語グリフが無いため、
      # 漢字がフォールバックで中国語字形(SC)になる。COSMIC 自身の設定
      # （com.system76.CosmicTk v1）でシステム/等幅フォントを JP 付きファミリに
      # 直接指定して回避する。noto-fonts-cjk は step_fonts で導入済み。
      write_cosmic_font_config
      # COSMIC のコンポジタ上では LibreOffice の gtk3 プラグインがネイティブ
      # Wayland だとメニューのポップアップを出せない（クリックしても開かない）。
      # gtk3 のまま XWayland 経由（GDK_BACKEND=x11）で動かすと回避できるため、
      # LibreOffice のランチャーだけに env を差し込む上書き .desktop を生成する。
      write_libreoffice_cosmic_launchers
      ;;



    hyprland)
      local pkgs=(hyprland hyprpaper hyprlock hypridle
                  waybar wofi kitty
                  alacritty fuzzel cava
                  # streamlink は desktop_common_pkgs へ移動（全DE共通）。
                  # Waybar の radiostation.sh が radiko の解決に使うが、
                  # 用途はそれに限らないため WM 側では重複させない。
                  xorg-xwayland
                  xdg-desktop-portal-hyprland xdg-desktop-portal-gtk
                  pavucontrol polkit-gnome
                  blueman
                  network-manager-applet
                  grim slurp wl-clipboard libnotify
                  mako
                  brightnessctl
                  nautilus
                  # 【重要】GUI アプリは nautilus に合わせて GTK 系で揃える。
                  # gedit / evince / file-roller なら見た目と操作感が一致し、
                  # GTK のポータルやファイル選択ダイアログも共通になる。
                  # 以前は mousepad(Xfce系) と zathura(vim風キーバインド) だったが、
                  # 単体では軽いものの見た目が浮き、zathura は既定操作が独特で
                  # 「PDF を開いたのにスクロールできない」と戸惑いやすい。
                  #
                  # xarchiver も GTK2 製で単独で浮くうえ、nautilus の右クリックに
                  # 統合されない。file-roller は nautilus 側から呼ばれて
                  # 「ここに展開」が使えるので、こちらに揃える（Budgie と同じ構成）。
                  #
                  # 【例外】画像ビューアだけは imv のまま残す。
                  # eog は GNOME 専用設計で他環境では浮き、後継の loupe は
                  # gnome-desktop 系の依存を引き込む。imv は Wayland ネイティブで
                  # タイル型 WM 向けに作られており、ここでは GTK 統一より
                  # 「Wayland で確実に動く」ことを優先する。
                  gedit evince imv file-roller
                  ttf-jetbrains-mono-nerd ttf-hack-nerd
                  "${host_waybar_deps[@]}")
      run_cmd_retry "Hyprland インストール" \
        arch-chroot /mnt pacman -S --noconfirm --needed "${pkgs[@]}" "${desktop_common_pkgs[@]}"

      # ── 【要追跡 / 2026-08-15 時点】設定ファイル形式について ──
      # Hyprland 0.55.0（2026-05-09）で設定言語が hyprlang(hyprland.conf) から
      # Lua(hyprland.lua) へ移行した。0.55 以降は
      #   ・~/.config/hypr/hyprland.lua があればそれを読む
      #   ・無ければ hyprland.conf を読むが、非推奨バナーを表示する
      # という挙動になる。判定は起動時に一度だけ行われる。
      #   ・参考: https://hypr.land/news/26_lua/
      #
      # 【重要】ここのバージョン定数に実在しない番号を書かないこと。
      # 以前は 0.56 / 0.56.1 と書いていたが、そのような版は存在せず（当時の最新は
      # 0.55.4）、結果として
      #   ・_check_pkg_version_gap が毎回「検証版と違う」と誤警告する
      #   ・_version_ge による非推奨検知は永久に成立せず、本当に必要な警告が出ない
      # という「警告が逆になる」状態だった。実在するリリース番号だけを書く。
      local HYPR_VERIFIED_VERSION="0.55"           # このHyprland設定ロジックを最後に検証したバージョン
      local HYPR_LUA_DEPRECATION_VERSION="0.55.0"  # hyprlang が非推奨になった版
      # 【重要】インストール済みバージョンの取得は「ベース設定を決める前」に行うこと。
      # 0.55 以上かどうかで .lua を生成するか .conf 経路に進むかが変わるため、
      # 従来のように後段で取得していると分岐に使えない。
      # `|| true` は _check_pkg_version_gap 内のコメントと同じ理由（pipefail 対策）。
      local hypr_installed_ver
      hypr_installed_ver=$(arch-chroot /mnt pacman -Q hyprland 2>/dev/null | awk '{print $2}') || true

      # ── ベースにする設定の決定 ──
      # 【重要】ホストPC / dotfiles の hypr/ があれば最優先で尊重する。
      # ユーザーが作り込んだ設定を .lua で上書きするのは論外なので、
      # その場合だけは hyprlang(.conf) のまま進め、非推奨である旨を警告する。
      # ホスト設定が無い場合は、0.55 以上なら .lua を生成する。
      # こうしないと最小フォールバックの .conf が使われ、起動のたびに
      # 「hyprland.conf は非推奨」バナーが出続ける。
      mkdir -p ${SKEL_ROOT}/.config/hypr
      local copied=0
      local hypr_from_host="no"
      local hypr_cfg_mode="conf"   # conf: hyprland.conf / lua: hyprland.lua
      local hypr_cfg=${SKEL_ROOT}/.config/hypr/hyprland.conf
      local host_home_hypr host_hypr_cfg="" host_hypr_lua=""
      host_home_hypr=$(_host_home)
      if [[ -n "$host_home_hypr" ]]; then
        host_hypr_cfg="${host_home_hypr}/.config/hypr/hyprland.conf"
        host_hypr_lua="${host_home_hypr}/.config/hypr/hyprland.lua"
      fi

      # 【注意】ドライランでは run_cmd が実際にはコピーしないため、これらの分岐に入ると
      # 直後の sed -i が存在しないファイルを触って set -e で落ちる。明示的に除外する。
      #
      # 【重要】.lua を .conf より先に判定すること。
      # Hyprland は両方あれば .lua だけを読む。順序を逆にすると、引き継ぎ元が
      # 移行期で両方持っている場合に「使われない .conf」を土台にしてしまう。
      if [[ "${CONFIG[dry_run]}" != "yes" && -n "$host_hypr_lua" && -f "$host_hypr_lua" ]]; then
        # 【重要】hyprland.lua 単体ではなく hypr/ ごと複製する。
        # hyprpaper.conf / hyprlock.conf / hypridle.conf や require() で読む
        # 分割ファイルが同じディレクトリにあるため、本体だけ持ち込むと壊れる。
        run_cmd "引き継ぎ元から Hyprland 設定 (Lua) をコピー" \
          bash -c 'cp -a "$1"/. "$2"/' _ "${host_home_hypr}/.config/hypr" ${SKEL_ROOT}/.config/hypr
        copied=1
        hypr_from_host="yes"
        hypr_cfg_mode="lua"
        hypr_cfg=${SKEL_ROOT}/.config/hypr/hyprland.lua

        # 【重要】.lua を採用したら .conf は消す。両方あると .lua だけが読まれるため、
        # 「.conf を編集しても何も変わらない」という原因の掴みにくい状態になる。
        rm -f ${SKEL_ROOT}/.config/hypr/hyprland.conf

        # polkit 認証エージェントのパス差を吸収する（本インストーラが入れるのは polkit-gnome）。
        # 単なるバイナリパスの文字列置換なので .lua でも安全。
        find ${SKEL_ROOT}/.config/hypr -type f \( -name '*.conf' -o -name '*.lua' \) \
          -exec sed -i 's|/usr/lib/polkit-kde-authentication-agent-1|/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1|g' {} +

        # 【重要】.lua には /home/<名前>/ → $HOME/ の置換を「しない」こと。
        # hyprlang では $HOME が設定側で展開されるが、Lua では単なる文字列であり、
        # 展開されるのは hl.exec_cmd などシェル経由で渡る箇所だけ。
        # 一律に置換すると、シェルを通らないパス指定が黙って壊れる。
        # 代わりに検出して知らせ、os.getenv("HOME") への修正を促す。
        if grep -qE '/home/[^/"'"'"' ]+/' ${SKEL_ROOT}/.config/hypr/hyprland.lua; then
          print_warn "Hyprland: hyprland.lua に特定ユーザーの絶対パス(/home/...)が含まれています。ユーザー名が異なる環境では動作しません。os.getenv(\"HOME\") を使う形へ修正してください。"
        fi

        print_ok "Hyprland: 引き継ぎ元の hypr/ 一式（Lua）をそのまま既定として適用しました"
      elif [[ "${CONFIG[dry_run]}" != "yes" && -n "$host_hypr_cfg" && -f "$host_hypr_cfg" ]]; then
        # 【重要】hyprland.conf 単体ではなく hypr/ ごと複製する。
        # hyprpaper.conf / hyprlock.conf / hypridle.conf は hyprland.conf から
        # 参照されるため、本体だけ持ち込むと壁紙もロック画面も既定に戻る。
        # 順序に注意: ディレクトリを先に複製してから下の sed を当てること。
        # 逆にすると書き換え済みの hyprland.conf を元のファイルで上書きしてしまう。
        run_cmd "ホストPCから Hyprland 設定をコピー" \
          bash -c 'cp -a "$1"/. "$2"/' _ "${host_home_hypr}/.config/hypr" ${SKEL_ROOT}/.config/hypr
        copied=1
        hypr_from_host="yes"

        # ホスト固有の絶対パスを $HOME 表記へ寄せる（ユーザー名が変わっても壊れないように）
        # basename ではなく /home/<任意> にマッチさせる（_host_home は ~/dotfiles を返しうる）
        find ${SKEL_ROOT}/.config/hypr -type f -name '*.conf' \
          -exec sed -i "s|/home/[^/\"' ]*/|\$HOME/|g" {} +

        # polkit 認証エージェントのパス差を吸収する（本インストーラが入れるのは polkit-gnome）
        find ${SKEL_ROOT}/.config/hypr -type f -name '*.conf' \
          -exec sed -i 's|/usr/lib/polkit-kde-authentication-agent-1|/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1|g' {} +

        print_ok "Hyprland: ホストPCの hypr/ 一式をそのまま既定として適用しました"
      elif [[ -n "$hypr_installed_ver" ]] && _version_ge "$hypr_installed_ver" "$HYPR_LUA_DEPRECATION_VERSION"; then
        # 【重要】この分岐はパッケージ既定の .conf 探索より「前」に置くこと。
        # 0.55 以降は .conf を土台にした時点で非推奨バナーが確定するため、
        # 既定の .conf が残っていても採用してはいけない。
        hypr_cfg_mode="lua"
        hypr_cfg=${SKEL_ROOT}/.config/hypr/hyprland.lua
        copied=1
        # 【重要】.conf を残さないこと。両方あると .lua だけが読まれるため、
        # 「.conf を編集しても何も変わらない」という分かりにくい状態になる。
        rm -f ${SKEL_ROOT}/.config/hypr/hyprland.conf
        print_ok "Hyprland ${hypr_installed_ver}: Lua 設定 (hyprland.lua) を生成します"
      elif [ -f /mnt/usr/share/hypr/hyprland.conf ]; then
        cp /mnt/usr/share/hypr/hyprland.conf "$hypr_cfg" && copied=1
      elif [ -f /mnt/etc/xdg/hypr/hyprland.conf ]; then
        cp /mnt/etc/xdg/hypr/hyprland.conf "$hypr_cfg" && copied=1
      elif [ -f /mnt/usr/share/hypr/hyprland.lua ] || [ -f /mnt/etc/xdg/hypr/hyprland.lua ]; then
        # 【検知】バージョン取得に失敗した（pacman -Q が空を返した等）が、
        # パッケージ既定は .lua になっている、という食い違いの場合のみここに来る。
        # 上の _version_ge 判定が通っていればこの分岐には入らない。
        print_warn "Hyprland: バージョンを判別できませんでしたが、パッケージ既定は hyprland.lua のようです。最小フォールバック設定(.conf)を使用するため、非推奨バナーが出る可能性があります（https://hypr.land/news/26_lua/ ）。"
      fi
      if [ $copied -eq 0 ]; then
        cat > ${SKEL_ROOT}/.config/hypr/hyprland.conf << 'EOF'
# Hyprland 最小フォールバック設定
monitor=,preferred,auto,auto
$mainMod = SUPER
bind = $mainMod, Q, exec, kitty
bind = $mainMod, C, killactive,
bind = $mainMod, M, exit,
EOF
      fi

      # ── バージョン差分の警告（点1・点4） ──
      # ホストPCの設定・パッケージ既定設定のどちらを土台にした場合でも、
      # 「検証した時点のバージョン」と実際にインストールされたバージョンが
      # 離れていれば、構文や既定値が変わっている可能性があるため知らせる。
      if [[ "$hypr_from_host" == "yes" ]]; then
        _check_pkg_version_gap "hyprland" "$HYPR_VERIFIED_VERSION" "Hyprland" "host"
      else
        _check_pkg_version_gap "hyprland" "$HYPR_VERIFIED_VERSION" "Hyprland" "base"
      fi
      # 非推奨バナーの予告は .conf を土台にしたときだけ意味を持つ。
      # .lua を生成した場合はバナーが出ないため、警告してはいけない。
      if [[ "$hypr_cfg_mode" == "conf" && -n "$hypr_installed_ver" ]] \
         && _version_ge "$hypr_installed_ver" "$HYPR_LUA_DEPRECATION_VERSION"; then
        print_warn "Hyprland ${hypr_installed_ver}: hyprland.conf(hyprlang) は非推奨です。起動時に非推奨バナーが出ます（.conf 自体の動作は当面継続）。将来のために hyprland.lua への移行を検討してください: https://hypr.land/news/26_lua/"
      fi

      if [[ "$hypr_cfg_mode" == "lua" ]]; then
        # ── Lua 設定経路（Hyprland 0.55 以降 / ホスト設定が無い場合）──
        # hyprland.lua に全部書くため、以下の .conf 向けの追記処理は一切通らない。
        # Waybar / 電源メニュー / スクリーンショットは別ファイルなので共通で生成する。
        write_waybar_config "hyprland"
        # 【順序注意】write_waybar_config の後に呼ぶこと（理由は関数のコメント参照）
        write_power_menu "hyprland"
        write_screenshot_script

        # ── 設定本体 ──
        # 引き継ぎ元（dotfiles リポジトリ等）の hyprland.lua を採用した場合は
        # 上書きしない。無い場合のみ Esca 既定の基本部分を生成する。
        if [[ "$hypr_from_host" != "yes" ]]; then
          write_hyprland_lua_base
        fi

        # ── 壁紙（hyprpaper）──
        # 【重要】hyprpaper はパッケージを入れるだけでは何も表示しない。
        # hyprpaper.conf と自動起動の両方が必要。自動起動は
        # append_hyprland_lua_local が壁紙の有無を見て入れてくれる。
        local hypr_wall
        hypr_wall=$(_install_wallpaper)
        if [[ -n "$hypr_wall" ]]; then
          # 【重要】引き継ぎ元が hyprpaper.conf を持っている場合は上書きしない。
          # 複数枚の壁紙や出力ごとの指定を書いている可能性がある。
          if [[ -f ${SKEL_ROOT}/.config/hypr/hyprpaper.conf ]]; then
            print_ok "壁紙: 引き継ぎ元の hyprpaper.conf を尊重します"
          else
            cat > ${SKEL_ROOT}/.config/hypr/hyprpaper.conf << EOF
# Esca Linux - hyprpaper 設定
#
# 【重要】preload = / wallpaper = <出力>,<パス> という旧書式を使わないこと。
# 現在の hyprpaper は wallpaper { ... } のブロック形式で、preload は廃止された。
# 旧書式で書くと解釈されず、画像もパッケージも正しいのに背景が真っ黒のまま
# という、極めて原因の分かりにくい症状になる。
# 参考: https://wiki.hypr.land/Hypr-Ecosystem/hyprpaper/
#
# monitor を空にすると全出力に適用されるフォールバックになる。
# 特定の出力だけ変えたい場合は monitor = DP-1 のように書く。
# パスは ~ を使わず絶対パスで書くこと（展開の扱いに差があるため）。
wallpaper {
    monitor =
    path = ${hypr_wall}
    fit_mode = cover
}

# IPC を切ると hyprctl hyprpaper wallpaper での切り替えができなくなる。
ipc = true

# 起動時のロゴ表示は不要
splash = false
EOF
            print_ok "壁紙: ${hypr_wall} を hyprpaper で表示します"
          fi
        else
          print_warn "壁紙画像を取得できなかったため、背景をテーマ色（#0d182c）で塗ります"
        fi

        # 【重要】ここで実体を確認しておくこと。
        # 壁紙が出ない不具合は「設定は正しいのに画像が無い」ことが原因の場合があり、
        # インストール後にログを見返しても判断できないと切り分けに時間がかかる。
        if [[ -n "$hypr_wall" && ! -f "/mnt${hypr_wall}" ]]; then
          print_warn "壁紙: 設定は書き込みましたが /mnt${hypr_wall} が見当たりません。初回ログイン後に背景が黒くなる可能性があります。"
        fi

        # 【順序注意】必ず _install_wallpaper の後に呼ぶこと。
        # 壁紙の有無で自動起動と背景色の書き分けが変わる。
        append_hyprland_lua_local "$hypr_wall"
      else
        # ── hyprlang 設定経路（0.55 未満、またはホストPCの .conf を引き継いだ場合）──
      # ── ビジュアル設定（角丸・カラー・アニメーション） ──
      # 【重要】ホストPC の設定を使う場合は追記しない。hyprland.conf は同じセクションが
      # 二度現れると後勝ちになるため、ここで general/decoration/animations を足すと
      # ユーザーが作り込んだ見た目を丸ごと上書きしてしまう。
      if [[ "$hypr_from_host" != "yes" ]]; then
      cat >> "$hypr_cfg" << 'EOF'

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
      cat >> "$hypr_cfg" << 'EOF'

# アプリ起動用の初心者向けキーバインド
bind = $mainMod, D, exec, wofi --show drun
bind = $mainMod SHIFT, F, exec, nautilus
bind = $mainMod SHIFT, W, exec, firefox
EOF
      fi   # hypr_from_host != yes

      # 自動起動設定（nm-applet の追加）
      _conf_append_once "$hypr_cfg" '^[[:space:]]*exec-once[[:space:]]*=.*nm-applet' \
        'exec-once = nm-applet --indicator'
      if [[ "${CONFIG[jp_ime]:-none}" =~ ^fcitx5 ]]; then
        # -r（replace）で既存プロセスを置き換え、環境変数の取りこぼしを防ぐ
        _conf_append_once "$hypr_cfg" '^[[:space:]]*exec-once[[:space:]]*=.*fcitx5' \
          'exec-once = fcitx5 -d -r'
      elif [[ "${CONFIG[jp_ime]:-none}" =~ ^ibus ]]; then
        _conf_append_once "$hypr_cfg" '^[[:space:]]*exec-once[[:space:]]*=.*ibus-daemon' \
          'exec-once = ibus-daemon -drx'
      fi

      # キーボードレイアウト設定（jp106 固定）
      # 【重要】ホスト設定に既に kb_layout がある場合は追記しない。input セクションを
      # 二重に書くと後勝ちで上書きされ、ユーザーの入力設定（トラックパッド等）が消える。
      if grep -qE '^[[:space:]]*kb_layout[[:space:]]*=' "$hypr_cfg"; then
        print_ok "Hyprland: 既存のキーボードレイアウト設定を尊重します（jp 設定の追記なし）"
      else
        printf 'input {\n    kb_layout = jp\n    kb_model = jp106\n}\n' >> "$hypr_cfg"
      fi

      # ── 日本語ロケールを Hyprland の環境に設定 ──
      # これが無いと fontconfig がフォールバックで中国語字形(SC)を選び、
      # ターミナル等の漢字が「変な字形」になる。
      if [[ "${CONFIG[japanese_env]}" == "yes" ]]; then
        local jp_locale="${CONFIG[locale]:-ja_JP.UTF-8}"
        _conf_append_once "$hypr_cfg" '^[[:space:]]*env[[:space:]]*=[[:space:]]*LANG,' \
          "env = LANG,${jp_locale}"
        _conf_append_once "$hypr_cfg" '^[[:space:]]*env[[:space:]]*=[[:space:]]*LC_CTYPE,' \
          "env = LC_CTYPE,${jp_locale}"
      fi

      # polkit 認証エージェントの自動起動設定（既に何らかの agent があれば追加しない）
      _conf_append_once "$hypr_cfg" '^[[:space:]]*exec-once[[:space:]]*=.*polkit.*authentication-agent' \
        'exec-once = /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1'

      # Waybar 設定の配置
      write_waybar_config "hyprland"
      # 【順序注意】write_waybar_config の後に呼ぶこと（理由は関数のコメント参照）
      write_power_menu "hyprland"

      # waybar の自動起動設定
      # 既定設定が waybar を起動する版もあるため、有効な exec-once...waybar が
      # 無い場合のみ追加する（二重起動の防止。コメント行 "# exec-once" は不一致）。
      _conf_append_once "$hypr_cfg" '^[[:space:]]*exec-once[[:space:]]*=.*waybar' \
        'exec-once = waybar'

      # ── 壁紙（hyprpaper）──
      # 【重要】hyprpaper はパッケージを入れるだけでは何も表示しない。
      # 設定ファイル(hyprpaper.conf)と exec-once の両方が必要。
      # さらに上の既定設定では disable_hyprland_logo = true にしているため、
      # ここで壁紙を出さないと Hyprland のロゴすら出ない完全な黒画面になる。
      local hypr_wall
      hypr_wall=$(_install_wallpaper)
      if [[ -n "$hypr_wall" ]]; then
        cat > ${SKEL_ROOT}/.config/hypr/hyprpaper.conf << EOF
# Esca Linux - hyprpaper 設定
#
# 【重要】preload = / wallpaper = <出力>,<パス> という旧書式を使わないこと。
# 現在の hyprpaper は wallpaper { ... } のブロック形式で、preload は廃止された。
# 旧書式で書くと解釈されず、画像もパッケージも正しいのに背景が真っ黒のまま
# という、極めて原因の分かりにくい症状になる。
# 参考: https://wiki.hypr.land/Hypr-Ecosystem/hyprpaper/
#
# monitor を空にすると全出力に適用されるフォールバックになる。
wallpaper {
    monitor =
    path = ${hypr_wall}
    fit_mode = cover
}

# IPC を切ると hyprctl hyprpaper wallpaper での切り替えができなくなる。
ipc = true

splash = false
EOF
        _conf_append_once "$hypr_cfg" '^[[:space:]]*exec-once[[:space:]]*=.*hyprpaper' \
          'exec-once = hyprpaper'
        print_ok "壁紙: ${hypr_wall} を hyprpaper で表示します"
      else
        # 画像が用意できなくても真っ黒にはしない。hyprpaper は画像必須なので
        # ここだけは Hyprland 側の背景色設定で代替する。
        # 【重要】'misc {' ブロックを追記する形にしないこと。
        # 上の既定設定生成で misc ブロックを既に書いているため、ブロック単位の
        # 重複チェックでは常に「存在する」と判定されて何も追加されない。
        # Hyprland は category:key の平坦記法を解釈できるのでそちらを使う。
        _conf_append_once "$hypr_cfg" '^[[:space:]]*misc:background_color' \
          'misc:background_color = 0x0d182c'
        print_warn "壁紙画像を取得できなかったため、背景をテーマ色（#0d182c）で塗ります"
      fi

      # 音量・輝度キーバインド:
      # 【重要】以前は「フォールバック設定を使った場合（copied=0）のみ追加」という
      # “パッケージの既定 example 設定には必ず入っている” 前提ベースの判定だった。
      # 将来のバージョンで既定 example からこのバインドが削られると、無音で
      # 欠落する（copied=1のまま、何も追加されない）ため、実際にファイルの中身を
      # 見て判定する方式に統一する。
      if ! grep -qE '^[[:space:]]*bind[a-z]*[[:space:]]*=.*XF86AudioRaiseVolume' "$hypr_cfg"; then
        cat >> "$hypr_cfg" << 'EOF'

# 音量・輝度キーのバインド（wpctl / brightnessctl 利用）
bindel = , XF86AudioRaiseVolume, exec, wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+
bindel = , XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
bindl = , XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
bindl = , XF86AudioMicMute, exec, wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle
bindel = , XF86MonBrightnessUp, exec, brightnessctl set 10%+
bindel = , XF86MonBrightnessDown, exec, brightnessctl set 10%-
EOF
        print_ok "Hyprland: 音量・輝度キーのバインドを追加しました"
      else
        print_ok "Hyprland: 音量・輝度キーのバインドは既に存在するため追加を見送りました"
      fi

      # ── 追加キーバインド ──
      # 【重要】ホストPC の設定を土台にした場合、同じキーが既に割り当てられていることが
      # ある。Hyprland は重複した bind を後勝ちで処理するため、素朴に追記すると
      # ユーザー自身の割り当てを黙って奪ってしまう。既存のキーには触れない。
      write_screenshot_script
      _conf_append_once "$hypr_cfg" \
        '^[[:space:]]*bind[a-z]*[[:space:]]*=[[:space:]]*(SUPER|\$mainMod)[[:space:]]*,[[:space:]]*B[[:space:]]*,' \
        'bind = SUPER, B, exec, pkill waybar || waybar'
      _conf_append_once "$hypr_cfg" \
        '^[[:space:]]*bind[a-z]*[[:space:]]*=[[:space:]]*,[[:space:]]*Print[[:space:]]*,' \
        'bind = , Print, exec, $HOME/.local/bin/screenshot.sh area'
      _conf_append_once "$hypr_cfg" \
        '^[[:space:]]*bind[a-z]*[[:space:]]*=[[:space:]]*SHIFT[[:space:]]*,[[:space:]]*Print[[:space:]]*,' \
        'bind = SHIFT, Print, exec, $HOME/.local/bin/screenshot.sh screen'
      fi
      ;;

    niri)
      local pkgs=(niri xwayland-satellite
                  waybar swaybg swaylock swayidle mako
                  alacritty fuzzel cava
                  # streamlink は desktop_common_pkgs へ移動（全DE共通）。
                  # Waybar の radiostation.sh が radiko の解決に使うが、
                  # 用途はそれに限らないため WM 側では重複させない。
                  xdg-desktop-portal-gnome xdg-desktop-portal-gtk
                  pavucontrol polkit-gnome
                  blueman
                  network-manager-applet
                  grim slurp wl-clipboard libnotify
                  brightnessctl
                  nautilus
                  # 【重要】Hyprland 側と同じ理由で GTK 系に揃える。
                  # nautilus を使っているので gedit / evince / file-roller が
                  # 操作感・ポータルともに一致する（file-roller は nautilus の
                  # 右クリック「ここに展開」から呼ばれる）。
                  # 画像ビューアだけは Wayland ネイティブの imv を残す。
                  # 片方だけ変えると構成がずれるので、変更するときは
                  # 必ず Hyprland 側と両方同時に直すこと。
                  gedit evince imv file-roller
                  ttf-jetbrains-mono-nerd ttf-hack-nerd
                  "${host_waybar_deps[@]}")
      run_cmd_retry "Niri インストール" \
        arch-chroot /mnt pacman -S --noconfirm --needed "${pkgs[@]}" "${desktop_common_pkgs[@]}"

      # ── バージョン定数（点1・点4と同様の考え方） ──
      # niri は 0.1.x のような番号ではなくカレンダーバージョニングを採用している。
      # 【重要】ゼロ埋めしないこと。実際のバージョン文字列は "26.4.0" であって
      # "26.04.0" ではない。_check_pkg_version_gap は前方一致で比較するため、
      # ここを "26.04" と書くと永久に一致せず、毎回警告が出続けることになる。
      local NIRI_VERIFIED_VERSION="26.4"  # このniri設定ロジックを最後に検証したバージョン
      # ── ベースにする config.kdl の決定 ──
      # ホストPC に ~/.config/niri/config.kdl があればそれを既定とする。
      # 使い込んだ設定（キーバインド・レイアウト・出力設定）をそのまま新環境へ
      # 持ち込むのが目的なので、ディストリ既定より必ず優先する。
      local niri_from_host="no"
      mkdir -p ${SKEL_ROOT}/.config/niri
      local host_home_niri host_niri_cfg=""
      host_home_niri=$(_host_home)
      [[ -n "$host_home_niri" ]] && host_niri_cfg="${host_home_niri}/.config/niri/config.kdl"

      # 【注意】ドライランでは run_cmd が実際にはコピーしないため、この分岐に入ると
      # 直後の sed -i が存在しないファイルを触って set -e で落ちる。明示的に除外する。
      if [[ "${CONFIG[dry_run]}" != "yes" && -n "$host_niri_cfg" && -f "$host_niri_cfg" ]]; then
        run_cmd "ホストPCから Niri 設定をコピー" \
          cp -a "$host_niri_cfg" ${SKEL_ROOT}/.config/niri/config.kdl
        niri_from_host="yes"

        # ホスト固有の絶対パスを $HOME 表記へ寄せる（ユーザー名が変わっても壊れないように）
        # basename ではなく /home/<任意> にマッチさせる（_host_home は ~/dotfiles を返しうる）
        sed -i "s|/home/[^/\"' ]*/|\$HOME/|g" ${SKEL_ROOT}/.config/niri/config.kdl

        # polkit 認証エージェントのパス差を吸収する。
        # ホストが KDE 版（polkit-kde）を指していても、本インストーラが入れるのは
        # polkit-gnome。存在しないパスを spawn すると認証ダイアログが出ず、
        # GParted や印刷設定などが「何も起きずに閉じる」状態になる。
        sed -i 's|/usr/lib/polkit-kde-authentication-agent-1|/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1|g' \
          ${SKEL_ROOT}/.config/niri/config.kdl

        print_ok "Niri: ホストPCの config.kdl をそのまま既定として適用しました"
      elif [ -f /mnt/usr/share/doc/niri/default-config.kdl ]; then
        cp /mnt/usr/share/doc/niri/default-config.kdl ${SKEL_ROOT}/.config/niri/config.kdl
      elif [ -f /mnt/usr/share/doc/niri/config.kdl ]; then
        cp /mnt/usr/share/doc/niri/config.kdl ${SKEL_ROOT}/.config/niri/config.kdl
      else
        # 【重要 / 検知】パッケージ既定の config.kdl がどちらのパスにも見つからない。
        # niri のファイル配置が変わった可能性があるため、無言でconfigなしのまま
        # 進めるのではなく、ここで警告してから空ファイルを用意する
        # （以降の処理は「ファイルが存在する」前提で書かれているため、
        #   最低限のバインド・ビジュアル設定だけは必ず入るようにする）。
        print_warn "Niri: パッケージ既定の config.kdl が見つかりませんでした（/mnt/usr/share/doc/niri/ 配下）。パッケージのファイル配置が変わった可能性があります。最小構成で作成します。"
        : > ${SKEL_ROOT}/.config/niri/config.kdl
      fi

      # ── バージョン差分の警告（点1） ──
      if [[ "$niri_from_host" == "yes" ]]; then
        _check_pkg_version_gap "niri" "$NIRI_VERIFIED_VERSION" "niri" "host"
      else
        _check_pkg_version_gap "niri" "$NIRI_VERIFIED_VERSION" "niri" "base"
      fi

      # ── Niri ビジュアル設定の適用 ──
      # 【重要】ホストPC の設定を使う場合はこの調整を丸ごと飛ばす。
      # 以下の sed はディストリ既定 config.kdl のコメント記法（/-window-rule、
      # "// active-color"、"// on"）を前提にしており、ユーザーが書いた設定に当てると
      # 無関係なコメント行を有効化してしまう。ホストの見た目を尊重するのが本来の意図でもある。
      # 【点3】各パターンが実際に一致したかを確認してから sed を当てる。
      # 既定config.kdlのコメント文言が変わってsedが1件もマッチしないと、
      # 何も変わっていないのに print_ok だけ出る「成功したふり」になるため、
      # 一致件数を数えて 0 件なら警告のうえ最小ビジュアル設定にフォールバックする。
      if [[ "$niri_from_host" == "yes" ]]; then
        : # ホストの設定をそのまま使う（ビジュアル調整はしない）
      elif [[ -f ${SKEL_ROOT}/.config/niri/config.kdl && -s ${SKEL_ROOT}/.config/niri/config.kdl ]]; then
        local niri_visual_cfg=${SKEL_ROOT}/.config/niri/config.kdl
        local niri_visual_hits=0

        # 1. 角丸ウィンドウルール
        # 【重要 / 2026-08-11 修正】以前は既定configの '/-window-rule {' を一括で
        # アンコメントしていたが、既定configには角丸ルールの他に
        # 「パスワードマネージャ(KeePassXC/Secrets)を画面キャプチャから黒塗りする」
        # ルールも /- でコメントアウトされており、一括アンコメントだとそちらまで
        # 意図せず有効化されていた（＝画面共有や録画でKeePassXCが真っ黒になる）。
        # niri は window-rule ノードを複数書けるため、既定configを書き換えずに
        # 自前のルールを追記する方式へ変更する。既定のコメント文言にも依存しない。
        # 【注意】重複ガードに 'geometry-corner-radius' を使ってはいけない。
        # 既定configの角丸ルールは "/-window-rule {" でノードごと無効化されているが、
        # ブロック内の geometry-corner-radius 行自体は普通の行として存在するため、
        # その文字列で判定すると「既にある」と誤判定して追記がスキップされる。
        # 自前のマーカーコメントで判定する（冪等性もこれで担保する）。
        if ! grep -qF '// Esca: rounded-corners' "$niri_visual_cfg"; then
          cat >> "$niri_visual_cfg" << 'EOF'

// Esca: rounded-corners / 全ウィンドウを角丸にする
window-rule {
    geometry-corner-radius 12
    clip-to-geometry true
}
EOF
        fi

        # 以下2つは layout{} ブロック内の設定であり、niri は layout ノードを
        # 複数書けない（重複するとパースエラーで設定全体が無効になる）ため、
        # 既定config内を直接書き換えるしかない。よって一致確認を必ず行う。
        # 2. フォーカスリング: アクティブグラデーション（テーマカラーに合わせる）
        # 【重要 / 2026-08-11 修正】以前は '// active-color "#7fc8ff"' という
        # 「コメントアウトされている前提」のパターンだったが、niri 実際の既定
        # config.kdl では該当行はコメントアウトされて*いない*（focus-ring 内に
        # 素の active-color "#7fc8ff" として存在する）。そのためこの sed は
        # 実際には一度も一致しておらず、print_ok だけ出る状態だった。
        # コメント有無どちらでも一致するように修正する。
        # なお border{} 側の active-color は "#ffc87f" と色が違うため誤爆しない。
        if grep -qE '^[[:space:]]*(//[[:space:]]*)?active-color "#7fc8ff"' "$niri_visual_cfg"; then
          sed -i -E 's|^([[:space:]]*)(//[[:space:]]*)?active-color "#7fc8ff"|\1active-gradient from="#1ca2f1" to="#3bc7ff" angle=45|' "$niri_visual_cfg"
          niri_visual_hits=$(( niri_visual_hits + 1 ))
        fi

        # 3. シャドウを有効化（コメントアウトされた '// on' を有効化）
        if grep -qE '^ *// on$' "$niri_visual_cfg"; then
          sed -i 's|^\( *\)// on$|\1on|' "$niri_visual_cfg"
          niri_visual_hits=$(( niri_visual_hits + 1 ))
        fi

        if [[ "$niri_visual_hits" -eq 2 ]]; then
          print_ok "Niri: 角丸・フォーカスリング・シャドウを設定しました"
        elif [[ "$niri_visual_hits" -eq 1 ]]; then
          print_warn "Niri: フォーカスリング/シャドウのうち片方しか既定config.kdlに一致しませんでした。既定のコメント文言や既定値が変わった可能性があります。見た目を確認してください。"
        else
          print_warn "Niri: 既定config.kdlの記述が変わったため、フォーカスリング・シャドウの自動設定に失敗しました（角丸は適用済み）。見た目を確認してください。"
        fi
      else
        # config.kdl 自体が無い/空の場合: 最小ビジュアル設定を追記
        cat >> ${SKEL_ROOT}/.config/niri/config.kdl << 'EOF'

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
      # 【重要】ホストPC の設定を土台にする場合、そのキーが既に使われていることがある。
      # niri は同じキーが二回現れると設定全体をパースエラーで捨てるため
      # （＝ログインしてもキーバインドが一切効かない状態になる）、
      # 既に有効な行として存在するキーは追加しない。
      local niri_cfg=${SKEL_ROOT}/.config/niri/config.kdl
      if [ -f "$niri_cfg" ]; then
        write_screenshot_script
        local niri_binds_file=/tmp/niri_binds.txt
        : > "$niri_binds_file"

        local key def added=0
        # "キー|定義" の順で並べる（定義側に | を含めないこと）
        local niri_bind_defs=(
          'Mod+E|    Mod+E { spawn "nautilus"; }'
          'Mod+Shift+B|    Mod+Shift+B { spawn "firefox"; }'
          'Mod+B|    Mod+B { spawn "sh" "-c" "pkill waybar || waybar"; }'
          'Print|    Print { spawn "sh" "-c" "$HOME/.local/bin/screenshot.sh area"; }'
          'Shift+Print|    Shift+Print { spawn "sh" "-c" "$HOME/.local/bin/screenshot.sh screen"; }'
        )
        for entry in "${niri_bind_defs[@]}"; do
          key="${entry%%|*}"
          def="${entry#*|}"
          # 行頭（インデント可）にそのキーがある行を探す。コメント行 "// Mod+E ..." は
          # ^[[:space:]]*Mod\+E に一致しないので、無効化済みのバインドは衝突扱いしない。
          if grep -qE "^[[:space:]]*${key//+/\\+}[[:space:]]" "$niri_cfg"; then
            continue
          fi
          echo "$def" >> "$niri_binds_file"
          added=$(( added + 1 ))
        done

        if [[ "$added" -gt 0 ]]; then
          if grep -q '^binds {' "$niri_cfg"; then
            sed -i "/^binds {/r ${niri_binds_file}" "$niri_cfg"
          else
            { echo 'binds {'; cat "$niri_binds_file"; echo '}'; } >> "$niri_cfg"
          fi
          print_ok "Niri: 追加バインドを ${added} 件登録しました（既存のキーは温存）"
        else
          print_ok "Niri: 追加バインドは既存設定と重複するため見送りました"
        fi
        rm -f "$niri_binds_file"
      fi

      # Waybar 設定の配置
      write_waybar_config "niri"
      # 【順序注意】write_waybar_config の後に呼ぶこと（理由は関数のコメント参照）
      write_power_menu "niri"

      # 自動起動設定（nm-applet などの追加）
      # waybar は niri のデフォルト設定が既に spawn-at-startup で起動するため、
      # 有効な spawn-at-startup "waybar" が無い場合のみ追加する（二重起動の防止）。
      # （コメント行 "// spawn-at-startup ..." は ^\s*spawn では一致しないので追加される）
      if ! grep -qE '^[[:space:]]*spawn-at-startup[[:space:]]+"waybar"' ${SKEL_ROOT}/.config/niri/config.kdl; then
        echo 'spawn-at-startup "waybar"' >> ${SKEL_ROOT}/.config/niri/config.kdl
      fi
      _conf_append_once "$niri_cfg" '^[[:space:]]*spawn-at-startup[[:space:]]+"nm-applet"' \
        'spawn-at-startup "nm-applet" "--indicator"'
      if [[ "${CONFIG[jp_ime]:-none}" =~ ^fcitx5 ]]; then
        # 【重要】niri-session は systemd の graphical-session.target を起動するため、
        # xdg-autostart-generator が /etc/xdg/autostart/org.fcitx.Fcitx5.desktop を
        # WAYLAND_DISPLAY のエクスポート前に起動してしまう（niri issue #2283）。
        # この壊れたインスタンスが spawn-at-startup 側の正常なインスタンスと競合し、
        # 「fcitx5 を再起動するまで日本語切り替えができない」症状になる。
        # → XDG autostart をユーザー単位で無効化し、起動経路を spawn-at-startup に一本化する
        mkdir -p ${SKEL_ROOT}/.config/autostart
        cat > ${SKEL_ROOT}/.config/autostart/org.fcitx.Fcitx5.desktop << 'FCITXEOF'
[Desktop Entry]
Type=Application
Name=Fcitx 5
Hidden=true
FCITXEOF
        # -r（replace）+ 2秒待機で、環境が整ってから確実に単一インスタンスで起動する。
        # 【重要】ホストPC の設定に素の spawn-at-startup "fcitx5" が既にある場合、
        # ここで足すと二重起動になる。その場合は既存行をこの安全な形へ置き換える。
        if grep -qE '^[[:space:]]*spawn-at-startup[[:space:]]+"fcitx5"' "$niri_cfg"; then
          sed -i 's|^\([[:space:]]*\)spawn-at-startup[[:space:]]\+"fcitx5".*$|\1spawn-at-startup "sh" "-c" "sleep 2 \&\& fcitx5 -d -r"|' "$niri_cfg"
        else
          _conf_append_once "$niri_cfg" '^[[:space:]]*spawn-at-startup.*fcitx5 -d -r' \
            'spawn-at-startup "sh" "-c" "sleep 2 && fcitx5 -d -r"'
        fi
      elif [[ "${CONFIG[jp_ime]:-none}" =~ ^ibus ]]; then
        _conf_append_once "$niri_cfg" '^[[:space:]]*spawn-at-startup[[:space:]]+"ibus-daemon"' \
          'spawn-at-startup "ibus-daemon" "-drx"'
      fi

      # ── キーボードレイアウト（既存 input/xkb 内へ挿入。input ブロックを重複させない）──
      # jp106 固定
      # 【重要】xkb ブロック内に既に有効な layout 行がある場合は触らない。
      # ホストPC の設定には通常 layout "jp" が書かれており、そこへ二つ目の layout を
      # 挿し込むと niri は重複キーとしてパースエラーを出し、設定全体が無効になる。
      local xkb_insert
      xkb_insert=$(printf '            layout "jp"\n            model "jp106"\n')
      if [[ -f "$niri_cfg" ]] && grep -qE '^[[:space:]]*layout[[:space:]]+"' "$niri_cfg"; then
        print_ok "Niri: 既存のキーボードレイアウト設定を尊重します（jp 設定の追記なし）"
      elif [[ -n "$xkb_insert" && -f "$niri_cfg" ]]; then
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

      # polkit 認証エージェントの自動起動設定（既に何らかの agent があれば追加しない）
      # 【重要】パターンは行頭 spawn-at-startup で固定する。単に 'polkit' を探すと
      # コメントアウト済みの行にも一致し、「認証エージェントが一つも起動しない」
      # 状態を有効と誤判定してしまう。
      _conf_append_once "$niri_cfg" '^[[:space:]]*spawn-at-startup.*polkit.*authentication-agent' \
        'spawn-at-startup "/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1"'

      # swayidle の自動起動設定（30分でロック、60分でサスペンド）
      _conf_append_once "$niri_cfg" '^[[:space:]]*spawn-at-startup[[:space:]]+"swayidle"' \
        'spawn-at-startup "swayidle" "-w" "timeout" "1800" "swaylock -f" "timeout" "3600" "systemctl suspend" "before-sleep" "swaylock -f"'

      # ── 壁紙（swaybg）──
      # 【重要】niri のデフォルト設定にも、引き継ぎ元の dotfiles にも
      # swaybg の spawn-at-startup は入っていない。パッケージを入れるだけでは
      # 壁紙は一切表示されず、真っ黒な画面になるため、ここで明示的に起動する。
      # -m fill: 画面比率に合わせて切り取りつつ全体を埋める（余白を出さない）
      local niri_wall
      niri_wall=$(_install_wallpaper)
      if [[ -n "$niri_wall" ]]; then
        _conf_append_once "$niri_cfg" '^[[:space:]]*spawn-at-startup[[:space:]]+"swaybg"' \
          "spawn-at-startup \"swaybg\" \"-i\" \"${niri_wall}\" \"-m\" \"fill\""
        print_ok "壁紙: ${niri_wall} を swaybg で表示します"
      else
        # 画像が用意できなくても背景が黒一色のままにはしない（テーマ色で塗る）
        _conf_append_once "$niri_cfg" '^[[:space:]]*spawn-at-startup[[:space:]]+"swaybg"' \
          'spawn-at-startup "swaybg" "-c" "#0d182c"'
        print_warn "壁紙画像を取得できなかったため、背景をテーマ色（#0d182c）で塗ります"
      fi

      print_ok "スクロール型タイリング: 横スクロールで無限ワークスペース"
      ;;
  esac

  # ── 壁紙（Hyprland / Niri 以外）──
  # Hyprland と Niri は上の各分岐で swaybg / hyprpaper の起動まで面倒を見ているので
  # ここでは対象外。それ以外の DE は DE 自身が壁紙を描画するため、
  # 「既定値をどこに書くか」だけが問題になる。
  case "${CONFIG[desktop]}" in
    gnome|budgie|cosmic|kde|xfce)
      local de_wall
      de_wall=$(_install_wallpaper)
      if [[ -n "$de_wall" ]]; then
        _set_de_wallpaper "${CONFIG[desktop]}" "$de_wall"
      else
        print_warn "壁紙画像を取得できなかったため、${CONFIG[desktop]} の壁紙は DE 既定のままにします"
      fi
      ;;
  esac

  # Hyprland, Niri 用の MIME デフォルト関連付け設定 (mimeapps.list)
  case "${CONFIG[desktop]}" in
    hyprland|niri)
      run_cmd "MIME デフォルト関連付け設定 (Hyprland/Niri)" bash -c "
        mkdir -p ${SKEL_ROOT}/.config
        cat > ${SKEL_ROOT}/.config/mimeapps.list << 'EOF'
[Default Applications]
text/html=firefox.desktop
x-scheme-handler/http=firefox.desktop
x-scheme-handler/https=firefox.desktop
x-scheme-handler/about=firefox.desktop
x-scheme-handler/unknown=firefox.desktop
inode/directory=org.gnome.Nautilus.desktop
text/plain=org.gnome.gedit.desktop
application/pdf=org.gnome.Evince.desktop
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
        mkdir -p ${SKEL_ROOT}/.config/alacritty
        cat > ${SKEL_ROOT}/.config/alacritty/alacritty.toml << 'EOF'
[font]
size = 11.0

[font.normal]
family = \"JetBrainsMono Nerd Font\"
style = \"Regular\"
EOF
      "
      ;;
  esac
  # 推奨アプリ（unzip/git/LibreOffice 等）はデスクトップ本体と
  # 同一トランザクションで導入済み（desktop_common_pkgs 参照）

  # デスクトップ用共通サービス（Bluetooth, CUPS, Avahi）有効化
  if [[ "${CONFIG[desktop]}" != "none" ]]; then
    run_cmd "Bluetooth サービス有効化" systemctl --root=/mnt enable bluetooth
    run_cmd "CUPS (印刷) サービス有効化" systemctl --root=/mnt enable cups
    run_cmd "Avahi (ネットワーク探索) サービス有効化" systemctl --root=/mnt enable avahi-daemon
    run_cmd "ローカルホスト名解決 (nss-mdns) の設定" sed -i '/^hosts:/ s/ \(resolve\|dns\)/ mdns_minimal [NOTFOUND=return] \1/' /mnt/etc/nsswitch.conf
  fi

  # ホストPCの各種アプリ設定をターゲットの /etc/skel にコピー
  if [[ "${CONFIG[dry_run]}" != "yes" ]]; then
    local host_home host_config_dir=""
    host_home=$(_host_home)
    [[ -n "$host_home" ]] && host_config_dir="${host_home}/.config"

    if [[ -d "$host_config_dir" ]]; then
      mkdir -p ${SKEL_ROOT}/.config

      # 【重要】「設定をコピーする対象」は「本体を導入する対象」と揃えること。
      # mpv は全DEに導入しているので常に引き継ぐ。
      # 一方 fuzzel / alacritty / mako / cava は Hyprland / Niri でしか
      # 導入していないため、他のDEにコピーすると本体の無い設定だけが
      # ホームに残り、「~/.config にあるのに動かない」原因不明のゴミになる。
      local app_configs=(mpv)

      # Hyprland / Niri ではホストPC の Waybar 設定をそのまま既定にしている。
      # その Waybar から呼ばれる周辺ツールの設定も一緒に持ち込まないと、
      # 電源メニュー（rofi のテーマを参照）やロック画面が既定の見た目に戻ってしまう。
      case "${CONFIG[desktop]}" in
        hyprland|niri) app_configs+=(fuzzel alacritty mako cava rofi swaylock ranger) ;;
      esac

      # 日本語入力の設定は DE に依存しないため、日本語環境なら常に引き継ぐ。
      # fcitx5 側に変換キー・句読点・キーバインドの設定が、mozc 側にユーザー辞書と
      # 学習履歴が入っている。ここを複製しないと「同じ操作感」にはならない。
      if [[ "${CONFIG[japanese_env]}" == "yes" && "${CONFIG[jp_ime]:-none}" =~ ^fcitx5 ]]; then
        app_configs+=(fcitx5 mozc)
      fi

      # 【重要】cp -a ではなく cp -aL（リンクを辿る）を使うこと。
      # dotfiles を git 管理して ~/.config/<app> からシンボリックリンクを張る運用では、
      # -a のままだと次の2つの壊れ方をする:
      #   1. リンク自体が複製され、インストール先には存在しないパスを指す
      #      リンク切れになる（エラーは出ず、設定だけが黙って既定に戻る）。
      #   2. コピー先に同名ディレクトリが既にある場合（alacritty がまさにそう。
      #      上の「alacritty フォント設定」で先に生成される）、cp は
      #      "cannot overwrite directory with non-directory" で失敗する。
      #      run_cmd は失敗で exit 1 するため、インストール全体が停止する。
      # -L なら実体がコピーされ、既存ディレクトリへはマージ（同名ファイルは上書き）される。
      for app in "${app_configs[@]}"; do
        if [[ -d "$host_config_dir/$app" ]]; then
          run_cmd "ホストPCから ${app} 設定をコピー" cp -aL "$host_config_dir/$app" ${SKEL_ROOT}/.config/
        fi
      done

      # ディレクトリではなく単体ファイルで置かれる設定（starship.toml 等）。
      # 上のループは -d 判定のため素通りしてしまうので個別に扱う。
      # starship は全インストール共通で導入するため、設定も DE を問わず引き継ぐ。
      local file_configs=(starship.toml)
      for f in "${file_configs[@]}"; do
        if [[ -f "$host_config_dir/$f" ]]; then
          run_cmd "ホストPCから ${f} をコピー" cp -aL "$host_config_dir/$f" ${SKEL_ROOT}/.config/
        fi
      done

      # 【順序注意】starship.toml をコピーした直後に呼ぶこと。
      # 置換対象は skel 上のファイルなので、コピー前に走らせても何も起きない。
      _strip_esca_glyph
      _fix_starship_nerdfont_v3

      # テーマを試した残骸（*.bak / *.bak_cyberpunk / *_bak）を配布前に落とす。
      # 設定ファイル本体と紛らわしく、どれが本番か分からなくなるため。
      # Waybar 側は write_waybar_config が既に同じ掃除をしている。
      run_cmd_soft "複製した設定のバックアップファイルを除去" \
        find ${SKEL_ROOT}/.config -type f \( -name '*.bak' -o -name '*.bak_*' -o -name '*_bak' -o -name '*.bak.*' \) -delete || true
    fi
  fi

  # 各一般ユーザーのホームディレクトリに /etc/skel の内容（デスクトップ設定含む）をコピー
  _sync_skel_to_homes
}

# ============================================
# ユーティリティ: /etc/skel を各ユーザーのホームへ配る
# ============================================
# do_desktop の末尾から呼ばれる。
# cp -a の上書きなので、複数回呼んでも結果は変わらない（冪等）。
_sync_skel_to_homes() {
  [[ "${CONFIG[dry_run]}" == "yes" ]] && return 0

  local entry uname upw usudo ushell ugroups
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    parse_users_line "$entry"
    [[ -d "/mnt/home/$uname" ]] || continue

    # 【重要】chown は必ず chroot 内で実行する。
    # ユーザーは chroot 内の useradd で作成されるため、ホスト（Live ISO）の
    # passwd DB には存在せず、ホスト側 chown は "invalid spec" で失敗する。
    run_cmd "ユーザー設定ファイルの同期: ${uname}" bash -c "
      cp -a ${SKEL_ROOT}/. /mnt/home/${uname}/
      arch-chroot /mnt chown -R ${uname}: /home/${uname}
    "
    # 【重要】arch-chroot は chroot に直接 exec するためシェルビルトインを渡せない。
    # 「arch-chroot /mnt command -v ...」は常に失敗するので、実体の有無で判定する。
    if [[ -x /mnt/usr/bin/xdg-user-dirs-update ]]; then
      run_cmd "ユーザーディレクトリ初期作成: ${uname}" \
        arch-chroot /mnt bash -c "
          HOME=/home/${uname} \
          LANG=${CONFIG[locale]} \
          XDG_CONFIG_HOME=/home/${uname}/.config \
          xdg-user-dirs-update --force
          chown -R ${uname}: /home/${uname}
        "
    fi

    # 【重要】選んだ DE を「既定セッション」として明示する。
    #
    # 実機で「Budgie を選んだのに GNOME で起動する」事象が起きた。原因は、
    # CONFIG[desktop] はスクリプト内部の変数にすぎず、ログイン後にどの
    # セッションが起動するかを決めているのは DM 側だから。
    # 特に gdm は gnome-shell / gnome-session に依存するため、Budgie を
    # 選んで GDM を入れると GNOME のセッションファイルも一緒に置かれ、
    # 一覧に両方が並ぶ。既定が未設定だと表示名順の先頭（GNOME）が選ばれる。
    #
    # GDM の既定セッションは AccountsService が保持しているので、初回
    # ログイン前にここへ書いておけば、意図した DE で起動する。
    # 利用者がログイン画面で別セッションを選べば、そちらで上書きされる
    # （固定はせず「初期値」を与えるだけに留める）。
    local sess=""
    case "${CONFIG[desktop]}" in
      gnome)    sess="gnome" ;;
      kde)      sess="plasma" ;;
      xfce)     sess="xfce" ;;
      budgie)   sess="budgie-desktop" ;;
      cosmic)   sess="cosmic" ;;
      hyprland) sess="hyprland" ;;
      niri)     sess="niri" ;;
    esac
    # 【重要】実在するセッションファイルのときだけ書くこと。
    # 存在しない名前を指定すると、DM がセッションを起動できず
    # ログイン画面に戻され続ける（利用者から見ると「ログインできない」）。
    if [[ -n "$sess" ]] \
       && { [[ -f "/mnt/usr/share/wayland-sessions/${sess}.desktop" ]] \
         || [[ -f "/mnt/usr/share/xsessions/${sess}.desktop" ]]; }; then
      run_cmd "既定セッションを ${sess} に設定: ${uname}" bash -c "
        mkdir -p /mnt/var/lib/AccountsService/users
        cat > /mnt/var/lib/AccountsService/users/${uname} << 'ASEOF'
[User]
Session=${sess}
XSession=${sess}
SystemAccount=false
ASEOF
        chmod 600 /mnt/var/lib/AccountsService/users/${uname}
      "
    elif [[ -n "$sess" ]]; then
      print_warn "セッションファイル ${sess}.desktop が見つからないため、既定セッションは設定しません（ログイン画面で選択してください）"
    fi
  done <<< "${CONFIG[users]}"
}
# ============================================
# SDDM テーマ「Esca」の書き込み
# ============================================
# テーマ一式をヒアドキュメントで直接書き出す。
#
# 【設計】ロゴは画像ではなく QML の Canvas で描いている（EscaLogo.qml）。
# PNG を base64 で埋めるとスクリプトが数十KB膨らんで読めなくなるため。
#
# 【設計】QtQuick.Controls を使っていない。スタイルプラグインが無い環境では
# 描画されず「ログイン画面が真っ白」になり、TTY からの復旧が必要になる。
#
# ヒアドキュメントは全て 'クォート付き' にしてある。QML 内の $ や ` を
# シェルに解釈させないため。
write_sddm_theme() {
  local theme_dir="/mnt/usr/share/sddm/themes/esca"

  if [[ "${CONFIG[dry_run]}" == "yes" ]]; then
    print_warn "SDDM テーマの書き込み (ドライラン - スキップ)"
    return 0
  fi

  mkdir -p "$theme_dir"

  cat > "${theme_dir}/Main.qml" <<'ESCA_MAIN_QML_EOF'
// Esca Linux — SDDM テーマ
//
// 【方針1】QtQuick.Controls を使わず QtQuick だけで組む。
//   Controls はスタイルプラグインが環境に無いと描画されず、
//   「ログイン画面が真っ白で操作できない」＝復旧が面倒な事態になる。
//   Rectangle と TextInput で自前に描けば QtQuick だけで完結する。
//
// 【方針2】import を 2.15 表記にする。Qt5.15 / Qt6 のどちらでも解釈できる。
//
// 【方針3】アイコンフォントを使わず日本語ラベルで書く。
//   ログイン画面はフォント設定が効く前なので、豆腐（□）になると詰む。

import QtQuick 2.15

Rectangle {
    id: root

    width: 1920
    height: 1080
    color: "#081726"

    // ---- 配色（アイコン・バナーと共通） ----
    readonly property color seaDeep:  "#081726"
    readonly property color seaMid:   "#122b45"
    readonly property color seaLight: "#1d4468"
    readonly property color rodLight: "#9adcf5"
    readonly property color glowGold: "#f8dd80"
    readonly property color textMain: "#e8f2f8"
    readonly property color textDim:  "#7f9db3"
    readonly property color errorRed: "#ff8b7a"

    property int    sessionIndex: sessionModel.lastIndex
    property string errorText: ""
    property string currentSessionName: ""

    // theme.conf の値。未設定でも動くよう既定値を用意する。
    // 日本語が豆腐になるのを避けるため CJK フォントを既定にしている。
    readonly property string uiFont: (typeof config !== "undefined" && config.font) ? config.font : "Noto Sans CJK JP"
    // 発光の脈動。theme.conf の animateGlow=false で止められる。
    // 文字列で来るため "false" との比較で判定する。
    readonly property bool animateGlow: (typeof config !== "undefined" && String(config.animateGlow) === "false") ? false : true

    // ============================================
    // 背景
    // ============================================
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0;  color: root.seaLight }
            GradientStop { position: 0.55; color: root.seaMid }
            GradientStop { position: 1.0;  color: root.seaDeep }
        }
    }

    // 深海の微粒子。数を絞って描画負荷を抑える
    Repeater {
        model: 40
        delegate: Rectangle {
            required property int index
            width: 2 + (index % 3)
            height: width
            radius: width / 2
            color: root.rodLight
            opacity: 0.05 + (index % 5) * 0.02
            x: (index * 137) % root.width
            y: (index * 271) % root.height
        }
    }

    // ============================================
    // 時計（右上）
    // ============================================
    Column {
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 48
        spacing: 4

        Text {
            id: clockTime
            anchors.right: parent.right
            color: root.textMain
            font.pixelSize: 52
            font.family: root.uiFont
            font.weight: Font.Light
            text: Qt.formatDateTime(new Date(), "HH:mm")
        }
        Text {
            id: clockDate
            anchors.right: parent.right
            color: root.textDim
            font.family: root.uiFont
            font.pixelSize: 17
            text: Qt.formatDateTime(new Date(), "yyyy年M月d日 dddd")
        }
    }

    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: {
            var now = new Date()
            clockTime.text = Qt.formatDateTime(now, "HH:mm")
            clockDate.text = Qt.formatDateTime(now, "yyyy年M月d日 dddd")
        }
    }

    // ============================================
    // 中央: ロゴとログインフォーム
    // ============================================
    Column {
        id: loginColumn
        anchors.centerIn: parent
        spacing: 20
        width: 380

        // ロゴは画像ではなく Canvas で描く（EscaLogo.qml）。
        // 画像ファイルを持たないので、install.sh への埋め込みが素直にできる。
        EscaLogo {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 132
            height: 132
            animated: root.animateGlow
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Esca Linux"
            color: root.textMain
            font.pixelSize: 26
            font.family: root.uiFont
            font.letterSpacing: 3
        }

        Item { width: 1; height: 12 }

        InputField {
            id: userField
            width: parent.width
            placeholder: "ユーザー名"
            text: userModel.lastUser
            accentColor: root.rodLight
            textColor: root.textMain
            hintColor: root.textDim
            onAccepted: passField.forceFocus()
        }

        InputField {
            id: passField
            width: parent.width
            placeholder: "パスワード"
            echoMode: TextInput.Password
            accentColor: root.rodLight
            textColor: root.textMain
            hintColor: root.textDim
            onAccepted: root.doLogin()
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.errorText
            color: root.errorRed
            font.pixelSize: 14
            visible: root.errorText !== ""
        }

        TextButton {
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            label: "ログイン"
            primary: true
            accentColor: root.rodLight
            onClicked: root.doLogin()
        }
    }

    // ============================================
    // 下部左: セッション選択
    // ============================================
    TextButton {
        id: sessionButton
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.margins: 36
        label: "セッション: " + root.currentSessionName
        textColor: root.textMain
        onClicked: sessionPopup.visible = !sessionPopup.visible
    }

    // ============================================
    // 下部右: 電源操作
    // ============================================
    Row {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 36
        spacing: 12

        TextButton {
            label: "スリープ"
            textColor: root.textMain
            visible: sddm.canSuspend
            onClicked: sddm.suspend()
        }
        TextButton {
            label: "再起動"
            textColor: root.textMain
            visible: sddm.canReboot
            onClicked: sddm.reboot()
        }
        TextButton {
            label: "シャットダウン"
            textColor: root.textMain
            visible: sddm.canPowerOff
            onClicked: sddm.powerOff()
        }
    }

    // セッション一覧。ボタンの真上に出す
    Rectangle {
        id: sessionPopup
        visible: false
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.leftMargin: 36
        anchors.bottomMargin: 88
        width: 300
        height: Math.min(sessionList.count * 40 + 12, 320)
        radius: 6
        color: "#0e2338"
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.14)

        ListView {
            id: sessionList
            anchors.fill: parent
            anchors.margins: 6
            clip: true
            model: sessionModel
            delegate: Rectangle {
                id: sessionRow
                required property int index
                required property string name
                width: sessionList.width - 12
                height: 40
                radius: 4
                color: hover.containsMouse ? Qt.rgba(1, 1, 1, 0.10) : "transparent"

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.leftMargin: 12
                    text: sessionRow.name
                    color: root.textMain
                    font.pixelSize: 14
                }

                MouseArea {
                    id: hover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        root.sessionIndex = sessionRow.index
                        root.currentSessionName = sessionRow.name
                        sessionPopup.visible = false
                    }
                }
            }
        }
    }

    // ============================================
    // ログイン処理
    // ============================================
    function doLogin() {
        root.errorText = ""
        if (userField.text.length === 0) {
            root.errorText = "ユーザー名を入力してください"
            return
        }
        sddm.login(userField.text, passField.text, root.sessionIndex)
    }

    Connections {
        target: sddm

        function onLoginFailed() {
            root.errorText = "ユーザー名またはパスワードが違います"
            passField.text = ""
            passField.forceFocus()
        }

        function onLoginSucceeded() {
            root.errorText = ""
        }
    }

    // 起動直後にフォーカスを合わせる。
    // ユーザー名が既に入っていればパスワード欄から始めるのが自然。
    Component.onCompleted: {
        if (userField.text.length > 0) {
            passField.forceFocus()
        } else {
            userField.forceFocus()
        }
    }
}
ESCA_MAIN_QML_EOF

  cat > "${theme_dir}/InputField.qml" <<'ESCA_INPUTFIELD_QML_EOF'
// 入力欄の共通部品（ユーザー名・パスワードで使い回す）
//
// 【重要】枠の半透明に opacity を使わないこと。
// opacity は子に継承されるため、中の文字まで薄くなって読めなくなる。
// Qt.rgba() で色そのものにアルファを持たせれば、文字は不透明のまま。

import QtQuick 2.15

Rectangle {
    id: field

    property alias text: input.text
    property alias echoMode: input.echoMode
    property string placeholder: ""
    property color textColor: "#e8f2f8"
    property color hintColor: "#7f9db3"
    property color accentColor: "#9adcf5"

    signal accepted()

    height: 48
    radius: 6
    color: Qt.rgba(1, 1, 1, 0.08)
    border.width: input.activeFocus ? 2 : 1
    border.color: input.activeFocus ? accentColor : Qt.rgba(1, 1, 1, 0.14)

    Behavior on border.color {
        ColorAnimation { duration: 120 }
    }

    TextInput {
        id: input
        anchors.fill: parent
        anchors.leftMargin: 16
        anchors.rightMargin: 16
        verticalAlignment: TextInput.AlignVCenter
        color: field.textColor
        font.pixelSize: 16
        selectByMouse: true
        selectionColor: field.accentColor
        selectedTextColor: "#081726"
        clip: true
        onAccepted: field.accepted()
    }

    Text {
        anchors.left: parent.left
        anchors.leftMargin: 16
        anchors.verticalCenter: parent.verticalCenter
        text: field.placeholder
        color: field.hintColor
        font.pixelSize: 16
        visible: input.text.length === 0 && !input.activeFocus
    }

    function forceFocus() {
        input.forceActiveFocus()
    }
}
ESCA_INPUTFIELD_QML_EOF

  cat > "${theme_dir}/TextButton.qml" <<'ESCA_TEXTBUTTON_QML_EOF'
// 文字ラベルのボタン。電源操作・セッション選択・ログインで使う。
//
// アイコンフォントに依存すると環境によって豆腐（□）になるため、
// ラベルは日本語テキストで書く。ログイン画面で読めないのは致命的。

import QtQuick 2.15

Rectangle {
    id: button

    property string label: ""
    property bool primary: false
    property color accentColor: "#9adcf5"
    property color textColor: "#e8f2f8"

    signal clicked()

    implicitWidth: labelText.implicitWidth + 40
    implicitHeight: 40
    radius: 6

    color: {
        if (primary) {
            return mouse.pressed ? Qt.darker(accentColor, 1.25)
                 : mouse.containsMouse ? Qt.lighter(accentColor, 1.1)
                 : accentColor
        }
        return mouse.pressed ? Qt.rgba(1, 1, 1, 0.20)
             : mouse.containsMouse ? Qt.rgba(1, 1, 1, 0.13)
             : Qt.rgba(1, 1, 1, 0.06)
    }

    border.width: primary ? 0 : 1
    border.color: Qt.rgba(1, 1, 1, 0.12)

    Behavior on color {
        ColorAnimation { duration: 100 }
    }

    Text {
        id: labelText
        anchors.centerIn: parent
        text: button.label
        color: button.primary ? "#081726" : button.textColor
        font.pixelSize: 15
        font.bold: button.primary
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: button.clicked()
    }
}
ESCA_TEXTBUTTON_QML_EOF

  cat > "${theme_dir}/EscaLogo.qml" <<'ESCA_ESCALOGO_QML_EOF'
// Esca のロゴ。発光をゆっくり脈打たせる。
//
// 【性能上の設計】Canvas を毎フレーム再描画すると CPU を食う。
// そこで「発光」と「本体（竿・球）」を別レイヤーに分け、
// 描画は起動時の一度だけ、アニメーションは発光レイヤーの
// opacity と scale だけを動かす。これは GPU 側の変形処理で完結する。
//
// 画像ファイルを使わない理由:
//   install.sh に埋め込む際、PNG は base64 で数十KB に膨らみ、
//   スクリプトが読めなくなる。SVG も Qt 側に qt6-svg が要る。
//
// 座標は 256x256 のアートボードを基準に書き、s で実サイズへ拡縮する。

import QtQuick 2.15

Item {
    id: logo

    width: 132
    height: 132

    // theme.conf から切れるようにしておく（低スペック機や好みへの配慮）
    property bool animated: true

    readonly property real s: width / 256.0
    // esca の中心（アートボード基準 188,126）
    readonly property real bulbX: 188 * s
    readonly property real bulbY: 126 * s

    // ============================================
    // 発光レイヤー（これだけが動く）
    // ============================================
    // 拡大しても切れないよう、親より大きめに取って中心を合わせる。
    Canvas {
        id: glowLayer

        width: 220 * logo.s
        height: 220 * logo.s
        x: logo.bulbX - width / 2
        y: logo.bulbY - height / 2
        antialiasing: true
        transformOrigin: Item.Center

        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var cx = width / 2
            var cy = height / 2
            var r = 84 * logo.s

            var glow = ctx.createRadialGradient(cx, cy, 0, cx, cy, r)
            glow.addColorStop(0.00, "rgba(255,246,204,0.90)")
            glow.addColorStop(0.30, "rgba(243,210,105,0.45)")
            glow.addColorStop(0.62, "rgba(239,192,26,0.16)")
            glow.addColorStop(1.00, "rgba(239,192,26,0.00)")
            ctx.fillStyle = glow
            ctx.beginPath()
            ctx.arc(cx, cy, r, 0, Math.PI * 2)
            ctx.fill()
        }

        // 発光の脈動。生物の発光らしく見せるため、
        // 明滅と膨張の周期をわずかにずらしている（同期すると機械的に見える）。
        // 【注意】初期値から「同じ値へ」向かうステップを先頭に置くと、
        // 最初の1周期が無変化になる（opacity 1.0 → to: 1.00）。
        // 初期値と逆方向へ動くステップから始めること。
        // また animated=false のときは初期値のまま静止するので、
        // 初期値は「通常の見た目」にしておく必要がある。
        SequentialAnimation on opacity {
            running: logo.animated
            loops: Animation.Infinite
            NumberAnimation { to: 0.62; duration: 2600; easing.type: Easing.InOutSine }
            NumberAnimation { to: 1.00; duration: 2600; easing.type: Easing.InOutSine }
        }

        SequentialAnimation on scale {
            running: logo.animated
            loops: Animation.Infinite
            NumberAnimation { to: 0.95; duration: 3100; easing.type: Easing.InOutSine }
            NumberAnimation { to: 1.07; duration: 3100; easing.type: Easing.InOutSine }
        }
    }

    // ============================================
    // 本体レイヤー（静止・描画は一度だけ）
    // ============================================
    Canvas {
        id: bodyLayer
        anchors.fill: parent
        antialiasing: true

        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var s = logo.s

            // ---- 竿（illicium）: 左下から立ち上がり右上へ ----
            var rod = ctx.createLinearGradient(34 * s, 224 * s, 186 * s, 66 * s)
            rod.addColorStop(0.00, "#24628f")
            rod.addColorStop(0.65, "#49a2d3")
            rod.addColorStop(1.00, "#9adcf5")
            ctx.strokeStyle = rod
            ctx.lineWidth = 13 * s
            ctx.lineCap = "round"
            ctx.beginPath()
            ctx.moveTo(34 * s, 224 * s)
            ctx.bezierCurveTo(60 * s, 190 * s, 66 * s, 146 * s, 92 * s, 112 * s)
            ctx.bezierCurveTo(116 * s, 80 * s, 152 * s, 62 * s, 186 * s, 66 * s)
            ctx.stroke()

            // ---- 竿先から垂れる糸 ----
            ctx.strokeStyle = "#9adcf5"
            ctx.lineWidth = 7 * s
            ctx.beginPath()
            ctx.moveTo(186 * s, 66 * s)
            ctx.bezierCurveTo(190 * s, 78 * s, 190 * s, 88 * s, 188 * s, 98 * s)
            ctx.stroke()

            // ---- esca 本体 ----
            var bulb = ctx.createRadialGradient(178 * s, 116 * s, 2 * s,
                                                188 * s, 126 * s, 30 * s)
            bulb.addColorStop(0.00, "#fffdf0")
            bulb.addColorStop(0.42, "#f8dd80")
            bulb.addColorStop(1.00, "#e0ab1c")
            ctx.fillStyle = bulb
            ctx.beginPath()
            ctx.arc(188 * s, 126 * s, 28 * s, 0, Math.PI * 2)
            ctx.fill()

            ctx.strokeStyle = "rgba(255,244,200,0.85)"
            ctx.lineWidth = 2.5 * s
            ctx.beginPath()
            ctx.arc(188 * s, 126 * s, 28 * s, 0, Math.PI * 2)
            ctx.stroke()

            // ---- 球に見せるハイライト ----
            ctx.fillStyle = "rgba(255,255,255,0.55)"
            ctx.beginPath()
            ctx.ellipse(170 * s, 109 * s, 18 * s, 14 * s)
            ctx.fill()
        }
    }
}
ESCA_ESCALOGO_QML_EOF

  cat > "${theme_dir}/theme.conf" <<'ESCA_THEME_CONF_EOF'
[General]
# ログイン画面で使うフォント。
# 日本語が豆腐（□）になるのを避けるため CJK 対応フォントを既定にする。
# ここを空にすると Qt の既定フォントになる。
font=Noto Sans CJK JP


# 下部のボタン表示。false にすると隠れる。
showSessionButton=true
showPowerButtons=true

# ロゴの発光をゆっくり脈打たせる。false で静止する。
# 発光レイヤーの opacity と scale だけを動かすので負荷は軽い。
animateGlow=true
ESCA_THEME_CONF_EOF

  cat > "${theme_dir}/metadata.desktop" <<'ESCA_METADATA_DESKTOP_EOF'
[SddmGreeterTheme]
Name=Esca
Description=Esca Linux 公式テーマ — 深海と発光する esca
Author=Esca Linux
Copyright=Esca Linux
License=MIT
Type=sddm-theme
# 【必須】Qt のバージョンを宣言する。
# これが無いと、Qt6 環境でも SDDM が正しいグリーターを選べず、
# 既定テーマへフォールバックもせずに真っ黒な画面になる。
# Arch の SDDM は Qt6 のため 6 を指定する。
QtVersion=6
Version=1.0
Website=@OS_HOME_URL@
MainScript=Main.qml
ConfigFile=theme.conf
TranslationsDirectory=
Email=
ESCA_METADATA_DESKTOP_EOF

  # 【重要】上のヒアドキュメントはデリミタを 'ESCA_METADATA_DESKTOP_EOF' と
  # クォートしているため、中では変数が一切展開されない（設定値を literal で
  # 書くために意図的にそうしている）。よって URL は @OS_HOME_URL@ という
  # プレースホルダで置き、ここで置換する。
  # 直接 ${OS_HOME_URL} と書くと、その文字列がそのままファイルに残る。
  sed -i "s|@OS_HOME_URL@|${OS_HOME_URL}|g" "${theme_dir}/metadata.desktop"

  # テーマを有効化する。既存の設定を壊さないよう専用ファイルに書く。
  mkdir -p /mnt/etc/sddm.conf.d
  cat > /mnt/etc/sddm.conf.d/10-theme.conf <<'ESCA_SDDM_CONF_EOF'
# Esca Linux のログインテーマ指定。
# 画面が出ずログインできない場合は、TTY (Ctrl+Alt+F2) からこのファイルを
# 削除して sddm を再起動すれば既定のテーマに戻る。
#   sudo rm /etc/sddm.conf.d/10-theme.conf && sudo systemctl restart sddm
[Theme]
Current=esca
ESCA_SDDM_CONF_EOF

  print_ok "SDDM テーマ「Esca」を配置しました"
}

do_display_manager() {
  local dm="${CONFIG[dm]}"
  [[ "$dm" == "none" ]] && { print_ok "DM なし: TTY から手動起動"; return; }

  print_step "ディスプレイマネージャーのセットアップ: ${dm}"

  case "$dm" in
    sddm)
      run_cmd_retry "SDDM インストール" \
        arch-chroot /mnt pacman -S --noconfirm --needed sddm
      run_cmd "SDDM 有効化" systemctl --root=/mnt enable sddm
      write_sddm_theme
      ;;

    gdm)
      run_cmd_retry "GDM インストール" \
        arch-chroot /mnt pacman -S --noconfirm --needed gdm
      run_cmd "GDM 有効化" systemctl --root=/mnt enable gdm
      ;;

    lightdm)
      run_cmd_retry "LightDM インストール" \
        arch-chroot /mnt pacman -S --noconfirm --needed \
          lightdm lightdm-gtk-greeter
      run_cmd "LightDM 有効化" systemctl --root=/mnt enable lightdm
      ;;

    cosmic-greeter)
      run_cmd_retry "cosmic-greeter インストール" \
        arch-chroot /mnt pacman -S --noconfirm --needed cosmic-greeter
      run_cmd "cosmic-greeter 有効化" \
        systemctl --root=/mnt enable cosmic-greeter
      ;;

    greetd)
      run_cmd_retry "greetd インストール" \
        arch-chroot /mnt pacman -S --noconfirm --needed greetd greetd-tuigreet

      # セッションコマンドを DE に応じて決める
      local session_cmd
      case "${CONFIG[desktop]}" in
        # Hyprland 0.53.0 以降は start-hyprland ラッパー経由で起動する。
        # （クラッシュリカバリ・セーフモードを提供するため、Hyprland バイナリの
        #   直接起動は非推奨になり、起動時に警告バナーが出る）
        # ※ 起動フラグを渡す場合は「start-hyprland -- -フラグ」の形にすること
        hyprland) session_cmd="start-hyprland" ;;
        niri)     session_cmd="niri-session" ;;
        kde)      session_cmd="startplasma-wayland" ;;
        cosmic)   session_cmd="start-cosmic" ;;
        # GNOME / Xfce / Budgie は greetd 非対応（step_dm でガード済み）。
        # ここに到達するのは想定外なので、素の bash を渡して黙って壊れるより
        # 気付けるようにしておく。
        *)
          print_warn "${CONFIG[desktop]} 用の greetd セッションコマンドが未定義です。"
          print_warn "ログイン後に手動でセッションを起動する必要があります。"
          session_cmd="bash"
          ;;
      esac

      # greetd 設定
      # ※ 生の mkdir / cat だとドライラン時も実行され、Live 環境に
      #    /mnt/etc/greetd/ を作ってしまうため run_cmd 経由にする
      run_cmd "greetd 設定ファイル作成" bash -c "mkdir -p /mnt/etc/greetd && \
        cat > /mnt/etc/greetd/config.toml << 'EOF'
[terminal]
vt = 1

[default_session]
command = \"tuigreet --time --remember --cmd ${session_cmd}\"
user = \"greeter\"
EOF"
      run_cmd "greetd 有効化" systemctl --root=/mnt enable greetd
      print_ok "greetd: セッションコマンド = ${session_cmd}"
      ;;
  esac
}
# 初回ログインガイドを各ユーザーのホームに作成する
# （完了画面の案内は再起動後に消えるため、ファイルとして残す）
write_first_login_guide() {
  [[ "${CONFIG[dry_run]}" == "yes" ]] && return 0
  [[ -z "${CONFIG[users]}" ]] && return 0

  local guide_tmp="/tmp/myarch_guide_$$.txt"
  {
    echo "========================================"
    echo " はじめにお読みください（Esca Linux）"
    echo "========================================"
    echo ""
    if [[ "${CONFIG[jp_ime]:-none}" =~ ^fcitx5 ]]; then
      echo "■ 日本語入力"
      echo "  ・オン/オフ切り替え: Ctrl + Space（または 半角/全角 キー）"
      echo "  ・切り替わらない場合は一度ログアウト → 再ログイン"
      echo "  ・うまく動かないときの診断: fcitx5-diagnose"
      echo ""
    fi
    echo "■ システムの更新"
    echo "  ・公式パッケージの更新: sudo pacman -Syu"
    if [[ "${CONFIG[aur_helper]:-none}" != "none" ]]; then
      echo "  ・AUR を含む更新     : yay -Syu"
      echo "  ・パッケージの検索   : yay -Ss キーワード"
      echo "  ・インストール       : yay -S パッケージ名"
    fi
    echo ""
    echo "■ AUR アプリを git で手動更新する方法"
    if [[ "${CONFIG[aur_helper]:-none}" != "none" ]]; then
      echo "  ※ yay を導入済みなら「yay -Syu」だけで AUR アプリ"
      if [[ "${CONFIG[install_chrome]:-no}" == "yes" ]]; then
        echo "    （Google Chrome 含む）もまとめて更新されます。"
      else
        echo "    もまとめて更新されます。"
      fi
      echo "    以下は yay を使わずに更新したい場合の手順です。"
    fi
    echo "  1. AUR からビルドファイルを取得（例: Google Chrome）"
    echo "       git clone https://aur.archlinux.org/google-chrome.git"
    echo "  2. ビルドしてインストール"
    echo "       cd google-chrome"
    echo "       makepkg -si"
    echo "  3. 片付け（ビルドファイルは残しておく必要はありません）"
    echo "       cd .. && rm -rf google-chrome"
    echo "  ※ 他の AUR パッケージも同じ手順です:"
    echo "     https://aur.archlinux.org/パッケージ名.git を clone → makepkg -si"
    if [[ "${CONFIG[install_ytfzf]:-no}" == "yes" ]]; then
      echo ""
      echo "  【注意】yt-fzf は GitHub 由来のため yay -Syu では更新されません。"
      echo "  更新するには同じ git 手順で再ビルドしてください:"
      echo "       git clone --depth=1 https://github.com/yannsi/yt-fzf-sh"
      echo "       cd yt-fzf-sh && makepkg -si"
      echo "       cd .. && rm -rf yt-fzf-sh"
    fi
    echo ""
    echo "■ プロンプト（starship）"
    echo "  ・設定ファイル: ~/.config/starship.toml"
    echo "  ・変更後は端末を開き直すと反映されます。"
    echo "  ・プリセット一覧と適用方法: starship preset --list"
    echo "  ・元の素のプロンプトに戻したい場合は、シェルの rc"
    echo "    （~/.bashrc / ~/.zshrc / ~/.config/fish/config.fish）末尾の"
    echo "    starship の行を削除してください。"
    echo ""
    echo "■ コンソール（TTY）フォント"
    echo "  ・設定ファイル: /etc/vconsole.conf（既定は FONT=ter-116n）"
    echo "  ・小さすぎる場合は大きいサイズに変更できます:"
    echo "       sudo sed -i 's/^FONT=.*/FONT=ter-124n/' /etc/vconsole.conf"
    echo "       sudo mkinitcpio -P     # 起動直後から反映させる場合"
    echo "  ・すぐ試すだけなら: setfont ter-124n"
    echo "  ・利用できるサイズ: ls /usr/share/kbd/consolefonts/ | grep '^ter-'"
    echo "  ※ TTY では Nerd Font のアイコンは表示できません（PSF の制約）。"
    echo "    starship の記号が崩れる場合は次で切り替えられます:"
    echo "       starship preset plain-text-symbols -o ~/.config/starship.toml"
    echo ""
    echo "■ Esca の壁紙"
    echo "  ・既定の壁紙は /usr/share/backgrounds/esca/esca.png にあります。"
    echo "  ・別の壁紙を使いたい場合は、画像を次の場所に置いてください:"
    echo "       sudo cp <画像> /usr/share/backgrounds/esca/"
    echo "  ・プロジェクトのページ:"
    echo "       ${OS_HOME_URL}"
    echo ""
    echo "■ ミラーが遅くなったら"
    echo "  sudo reflector --country Japan --protocol https --age 24 \\"
    echo "    --sort rate --number 8 --save /etc/pacman.d/mirrorlist"
    echo ""
    echo "■ 困ったときは"
    echo "  ・インストール時のログ: /var/log/$(basename "${CONFIG[log_file]}")"
    echo "  ・ArchWiki 日本語版   : https://wiki.archlinux.jp/"
    echo ""
    echo "（このファイルは不要になったら削除して構いません）"
  } > "$guide_tmp"

  local entry uname upw usudo ushell ugroups
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    parse_users_line "$entry"
    [[ -d "/mnt/home/${uname}" ]] || continue
    cp "$guide_tmp" "/mnt/home/${uname}/はじめにお読みください.txt"
    arch-chroot /mnt chown "${uname}:" "/home/${uname}/はじめにお読みください.txt" 2>/dev/null || true
  done <<< "${CONFIG[users]}"
  rm -f "$guide_tmp"
  print_ok "初回ログインガイドを各ユーザーのホームに作成しました"
}

do_cleanup() {
  print_step "後処理"

  # AUR ビルドの残骸フォルダを掃除（万一ビルドが途中で失敗した場合の保険）。
  # 各ユーザーのホーム直下 aur-build と、新方式の .cache/aur-build を空なら削除。
  if [[ "${CONFIG[dry_run]}" != "yes" ]]; then
    for _h in /mnt/home/*; do
      [[ -d "$_h" ]] || continue
      rm -rf "${_h}/aur-build" "${_h}/.cache/aur-build" 2>/dev/null || true
    done

    # 一時 NOPASSWD sudoers の取り残しを最終掃除（trap の二重保険）。
    # ここを通れば、どの経路で来ても NOPASSWD 設定は残らない。
    if compgen -G "/mnt/etc/sudoers.d/*-aur-nopasswd" > /dev/null; then
      rm -f /mnt/etc/sudoers.d/*-aur-nopasswd 2>/dev/null || true
      print_warn "一時的な sudo NOPASSWD 設定の残骸を削除しました"
    fi
  fi

  # 初回ログインガイド生成（アンマウント前に実施）
  write_first_login_guide

  # systemd-resolved の resolv.conf シンボリックリンク設定を最終段階でホスト側から実施
  if [[ "${CONFIG[use_resolved]}" == "yes" ]]; then
    run_cmd "resolv.conf シンボリックリンク設定" \
      ln -sf /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf
  fi

  # swapoff は swap がない場合でも失敗しないよう直接実行
  echo -ne "  ${CYAN}…${RESET} swap 無効化..."
  swapoff -a 2>/dev/null && echo -e "\r  ${GREEN}✔${RESET} swap 無効化   " || \
    echo -e "\r  ${GREEN}✔${RESET} swap なし（スキップ）"
  # インストールログを新システムに保存
  # （/tmp のログは再起動で消えるため、初回起動後のトラブルシュート用に残す）
  if [[ "${CONFIG[dry_run]}" != "yes" && -f "${CONFIG[log_file]}" && -d /mnt/var/log ]]; then
    cp "${CONFIG[log_file]}" /mnt/var/log/ 2>/dev/null \
      && print_ok "インストールログを保存: /var/log/$(basename "${CONFIG[log_file]}")" \
      || print_warn "ログのコピーに失敗しました（インストールには影響ありません）"
  fi

  # インストール自体は完了しているため、アンマウント失敗で exit しない
  echo -ne "  ${CYAN}…${RESET} アンマウント..."
  if [[ "${CONFIG[dry_run]}" == "yes" ]]; then
    echo -e "\r  ${YELLOW}⚠${RESET} アンマウント (ドライラン - スキップ)"
  elif umount -R /mnt >> "${CONFIG[log_file]}" 2>&1; then
    echo -e "\r  ${GREEN}✔${RESET} アンマウント   "
  else
    echo -e "\r  ${YELLOW}⚠${RESET} アンマウントに失敗（インストール自体は完了しています）"
    print_warn "再起動前に手動で実行してください: umount -R /mnt"
  fi
}

# ============================================
# インストール実行
# ============================================

run_install() {
  clear
  echo ""
  echo -e "  ${YELLOW}${BOLD}(o)${RESET} ${CYAN}${BOLD}${OS_NAME}${RESET}  ${GRAY}│${RESET}  ${BOLD}インストール実行中${RESET}"
  echo -e "  ${CYAN}$(printf '━%.0s' {1..48})${RESET}"
  echo ""

  # --- 進捗カウンター用の総ステップ数を算出（print_step が [n/N] を表示）---
  # 常に実行される9フェーズ + 条件付き3フェーズ
  STEP_NUM=0
  STEP_TOTAL=9
  # 【重要】ここの条件は do_aur_helper の早期 return 条件と必ず一致させること。
  # 食い違うと do_aur_helper だけが計上されず、進捗表示が [10/9] のように
  # 総数を超える（wlogout を AUR からビルドしていた頃に実際に起きた）。
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
    print_warn "生成される設定ファイルの確認先: ${SKEL_ROOT}"
  fi

  # 所要時間計測の開始
  INSTALL_START=$SECONDS
  STEP_LOG=()
  CURRENT_STEP_NAME=""
  CURRENT_STEP_TS=0

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

  # 最終ステップの所要時間を記録
  if [[ -n "${CURRENT_STEP_NAME:-}" ]]; then
    STEP_LOG+=("${CURRENT_STEP_NAME}|$(( SECONDS - CURRENT_STEP_TS ))")
    CURRENT_STEP_NAME=""
  fi
  STEP_TOTAL=0

  echo ""
  echo -e "  ${GREEN}${BOLD}✔ インストール完了！${RESET}  ${GRAY}再起動して日本語環境をお楽しみください${RESET}"
  echo -e "  ${GREEN}$(printf '━%.0s' {1..48})${RESET}"
  echo ""
  # ステップ別所要時間サマリー
  if [[ "${#STEP_LOG[@]}" -gt 0 ]]; then
    echo -e "  ${BOLD}ステップ別所要時間:${RESET}"
    for _entry in "${STEP_LOG[@]}"; do
      _sname="${_entry%|*}"
      _ssec="${_entry##*|}"
      echo -e "    ${GRAY}•${RESET} ${_sname}: $(( _ssec / 60 ))分$(( _ssec % 60 ))秒"
    done
    echo -e "  ${BOLD}総所要時間: $(( (SECONDS - INSTALL_START) / 60 ))分$(( (SECONDS - INSTALL_START) % 60 ))秒${RESET}"
    echo ""
  fi
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
  # 一時 NOPASSWD sudoers の取り残し防止（Ctrl+C / 途中失敗でも必ず消す）
  trap _cleanup_temp_sudoers EXIT
  trap _on_interrupt INT TERM
  trap _on_error ERR

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

  # 起動時のみ大きいロゴを出す。以降のステップは print_header（1行版）
  print_logo
  echo -e "  Arch Linux をベースに、日本語環境まで含めて自動構築します。"
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
  step_config_source
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
      "システム設定を変更する（ホスト名・デュアルブート・GPUなど）" \
      "ユーザー設定を変更する" \
      "ブートローダーを変更する" \
      "デスクトップ環境を変更する" \
      "設定の引き継ぎを変更する（ホストPC / GitHub / なし）" \
      "ネットワーク設定を変更する" \
      "追加パッケージを変更する" \
      "キャンセルして終了する")

    case "$action" in
      "このままインストールを実行する") break ;;
      "ディスクを変更する")                                   step_disk ;;
      "パーティション構成・ファイルシステムを変更する")       step_partition_scheme ;;
      "システム設定を変更する（ホスト名・デュアルブート・GPUなど）") step_system ;;
      "ユーザー設定を変更する")                     step_users ;;
      "ブートローダーを変更する")                   step_bootloader ;;
      "デスクトップ環境を変更する")                 step_desktop ;;
      "設定の引き継ぎを変更する（ホストPC / GitHub / なし）") step_config_source ;;
      "ネットワーク設定を変更する")                 step_network ;;
      "追加パッケージを変更する")                   step_extra_packages ;;
      "キャンセルして終了する")
        echo -e "\n  インストールを中断しました。"
        exit 0
        ;;
    esac

    # 修正後にサマリーを再表示
    show_summary
  done

  # デュアルブート + 自動パーティションの安全確認
  # （自動スキームは sgdisk --zap-all でディスク全体を消去するため、
  #   同一ディスク上の Windows も消える。ここで最終ガードを掛ける）
  if [[ "${CONFIG[dualboot_windows]}" == "yes" && "${CONFIG[partition_scheme]}" != "manual" ]]; then
    echo ""
    print_warn "「Windows を残す」設定ですが、パーティション構成が「自動」のままです。"
    print_warn "このまま進むと ${CONFIG[disk]} は全体が消去され、"
    print_warn "そこに Windows がある場合は Windows も一緒に消えます。"
    echo ""
    echo "      Windows が別のディスクにある場合のみ、このまま進めます。"
    echo "      同じディスクにある場合は「いいえ」を選んで中断してください。"
    echo ""
    if ! confirm "Windows は ${CONFIG[disk]} とは別のディスクにありますか？"; then
      print_err "中断しました。Windows を残すには、設定の修正メニューから"
      print_err "パーティション構成を「手動（fdisk）」に変更し、"
      print_err "Windows のパーティションには触れずに空き領域へ作成してください。"
      exit 1
    fi
  fi

  echo ""
  print_warn "この操作は取り消せません。ディスク ${CONFIG[disk]} の全データが完全に消去されます。"
  local final_confirm
  local tty_out tty_in; _resolve_tty tty_out tty_in
  echo -ne "  ${BOLD}${RED}実行する場合は大文字で YES と入力してください${RESET}: " > "$tty_out"
  _read_input final_confirm "$tty_in" "$tty_out"
  if [[ "$final_confirm" != "YES" ]]; then
    echo -e "\n  インストールをキャンセルしました。"
    exit 0
  fi
  run_install
}

main "$@"
