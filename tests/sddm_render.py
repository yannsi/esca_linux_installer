#!/usr/bin/env python3
"""SDDM テーマ「Esca」を実際に描画して確かめるテスト。

install.sh のヒアドキュメントから QML 一式を取り出し、SDDM 本体の代わりに
模擬の部品（sddm / sessionModel / userModel / config）を差し込んで描画する。
ログイン画面の不具合はインストール後でないと気付けず、真っ白・真っ黒に
なると TTY からの復旧が必要になるため、ここで事前に確認する。

確認すること:
  - QML の読み込みエラーが無い
  - 起動直後からセッション名が表示される
  - ログイン失敗時にメッセージが出る
  - Tab でユーザー名欄とパスワード欄を行き来できる
  - theme.conf の showSessionButton / showPowerButtons=false でボタンが隠れる

使い方: QT_QPA_PLATFORM=offscreen python3 tests/sddm_render.py [--out 画像.png]
必要なもの: PySide6（pip install PySide6-Essentials）
"""
import argparse
import os
import re
import sys
import tempfile
import warnings

# PySide6 の QQmlPropertyMap() は非推奨警告を出すが、テストの結果には影響しない
warnings.filterwarnings("ignore", category=DeprecationWarning)

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
os.environ.setdefault("QT_QUICK_BACKEND", "software")

from PySide6.QtCore import (QAbstractListModel, QModelIndex, QObject, QTimer,
                            QUrl, Qt, Property, Signal, Slot, QMetaObject)
from PySide6.QtGui import QGuiApplication
from PySide6.QtQml import QQmlPropertyMap
from PySide6.QtQuick import QQuickView
from PySide6.QtTest import QTest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILES = {
    "Main.qml": "ESCA_MAIN_QML_EOF",
    "InputField.qml": "ESCA_INPUTFIELD_QML_EOF",
    "TextButton.qml": "ESCA_TEXTBUTTON_QML_EOF",
    "EscaLogo.qml": "ESCA_ESCALOGO_QML_EOF",
    "theme.conf": "ESCA_THEME_CONF_EOF",
}


def extract_theme(dest):
    """install.sh から <<'DELIM' ... DELIM の本文を取り出してファイルに書く。"""
    src = open(os.path.join(ROOT, "install.sh"), encoding="utf-8").read()
    for name, delim in FILES.items():
        m = re.search(r"<<'%s'\n(.*?)\n%s\n" % (delim, delim), src, re.S)
        if not m:
            sys.exit(f"install.sh に {delim} が見つかりません")
        with open(os.path.join(dest, name), "w", encoding="utf-8") as f:
            f.write(m.group(1) + "\n")


class Sddm(QObject):
    loginFailed = Signal()
    loginSucceeded = Signal()

    def __init__(self):
        super().__init__()
        self.calls = []

    @Property(bool, constant=True)
    def canSuspend(self): return True

    @Property(bool, constant=True)
    def canReboot(self): return True

    @Property(bool, constant=True)
    def canPowerOff(self): return True

    @Slot(str, str, int)
    def login(self, user, password, session):
        self.calls.append((user, session))
        (self.loginSucceeded if password == "正しいパスワード" else self.loginFailed).emit()

    @Slot()
    def suspend(self): self.calls.append("suspend")

    @Slot()
    def reboot(self): self.calls.append("reboot")

    @Slot()
    def powerOff(self): self.calls.append("poweroff")


class Sessions(QAbstractListModel):
    NAME = Qt.UserRole + 4  # SDDM の SessionModel と同じロール番号

    def __init__(self, names, last):
        super().__init__()
        self._names, self._last = names, last

    def rowCount(self, parent=QModelIndex()): return len(self._names)

    def data(self, index, role):
        return self._names[index.row()] if role == self.NAME else None

    def roleNames(self): return {self.NAME: b"name"}

    @Property(int, constant=True)
    def lastIndex(self): return self._last


class Users(QObject):
    @Property(str, constant=True)
    def lastUser(self): return "sk"


FAILS = []


def check(cond, msg):
    print(("  OK   " if cond else "  NG   ") + msg)
    if not cond:
        FAILS.append(msg)


def labels(root):
    out = {}
    for o in root.findChildren(QObject):
        lab = o.property("label")
        if lab:
            parent = o.parent()
            visible = bool(o.property("visible")) and (parent is None or parent.property("visible") is not False)
            out[str(lab)] = visible
    return out


def run(theme_dir, conf_overrides, out_png=None):
    view = QQuickView()
    view.setResizeMode(QQuickView.SizeRootObjectToView)
    ctx = view.rootContext()
    sddm, sessions, users = Sddm(), Sessions(["COSMIC", "Plasma (Wayland)"], 0), Users()
    cfg = QQmlPropertyMap()
    for line in open(os.path.join(theme_dir, "theme.conf"), encoding="utf-8"):
        if "=" in line and not line.lstrip().startswith(("#", "[")):
            k, v = line.strip().split("=", 1)
            cfg.insert(k, conf_overrides.get(k, v))
    for name, obj in (("sddm", sddm), ("sessionModel", sessions), ("userModel", users), ("config", cfg)):
        ctx.setContextProperty(name, obj)
    view.setSource(QUrl.fromLocalFile(os.path.join(theme_dir, "Main.qml")))
    if view.status() == QQuickView.Error:
        for e in view.errors():
            print("  QML エラー:", e.toString())
        check(False, "QML を読み込める")
        return
    view.resize(1366, 768)
    view.show()
    view.requestActivate()
    result = {}

    def focused():
        it = view.activeFocusItem()
        if it is None:
            return "なし"
        if not it.property("text"):
            it.setProperty("text", "a")
            masked = it.property("displayText") != "a"
            it.setProperty("text", "")
        else:
            masked = it.property("displayText") != it.property("text")
        return "パスワード" if masked else "ユーザー名"

    def step():
        root = view.rootObject()
        result["labels"] = labels(root)
        result["focus0"] = focused()
        QTest.keyClick(view, Qt.Key_Tab)
        result["focus1"] = focused()
        QTest.keyClick(view, Qt.Key_Tab)
        result["focus2"] = focused()
        QMetaObject.invokeMethod(root, "doLogin")
        QGuiApplication.processEvents()
        result["error"] = root.property("errorText")
        if out_png:
            view.grabWindow().save(out_png)
        QGuiApplication.quit()

    QTimer.singleShot(600, step)
    QGuiApplication.exec()
    # 模擬の部品より先に QML を破棄する（逆順だと終了時に null 参照の警告が出る）
    view.setSource(QUrl())
    view.close()
    del sddm, sessions, users, cfg
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", help="描画結果の保存先 PNG")
    args = ap.parse_args()
    QGuiApplication(sys.argv)

    with tempfile.TemporaryDirectory() as d:
        extract_theme(d)

        print("== 既定の設定")
        r = run(d, {}, args.out)
        if r is None:
            sys.exit(1)
        session = [k for k in r["labels"] if k.startswith("セッション")]
        check(session == ["セッション: COSMIC"], f"起動直後からセッション名が出る（{session}）")
        check(r["labels"].get("シャットダウン") is True, "電源ボタンが表示される")
        check(r["focus0"] == "パスワード", f"前回のユーザー名があればパスワード欄から始まる（{r['focus0']}）")
        check((r["focus1"], r["focus2"]) == ("ユーザー名", "パスワード"),
              f"Tab で欄を行き来できる（{r['focus1']} → {r['focus2']}）")
        check(r["error"] == "ユーザー名またはパスワードが違います", "ログイン失敗時にメッセージが出る")

        print("== showSessionButton / showPowerButtons = false")
        r = run(d, {"showSessionButton": "false", "showPowerButtons": "false"})
        session = [k for k in r["labels"] if k.startswith("セッション")]
        check(session and r["labels"][session[0]] is False, "セッションボタンが隠れる")
        check(r["labels"].get("シャットダウン") is False, "電源ボタンが隠れる")

    print(f"\n結果: 失敗 {len(FAILS)} 件")
    sys.exit(1 if FAILS else 0)


if __name__ == "__main__":
    main()
