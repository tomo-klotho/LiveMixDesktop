#!/usr/bin/env python3
"""GV-LSMIXER/I (ATEN UC9020 系) を Mac から操作する CLI。

本体の RESTful API (https://192.168.254.1/api/v2.0) を使う。標準ライブラリのみ。

  ./livemix.py login                 # ユーザー名/パスワードを聞いてログイン (クッキー保存)
  ./livemix.py status                # 機器情報・チャンネル・トランジション
  ./livemix.py scenes                # シーン 1〜8 と PRV/PGM の割り当て
  ./livemix.py pgm 2                 # Program にシーン 2 を割り当て
  ./livemix.py prv 3                 # Preview にシーン 3 を割り当て
  ./livemix.py cut | auto [ms]       # PRV → PGM へカット / オート切替
  ./livemix.py audio                 # 音声の入出力一覧
  ./livemix.py vol mic -6            # 入力 (名前の一部か id) を -6 dB に
  ./livemix.py mute hdmi1 / unmute hdmi1
  ./livemix.py get /source           # 任意の GET (調査用)

環境変数: LMD_HOST (既定 192.168.254.1), LMD_USER, LMD_PASS
"""
import argparse
import base64
import getpass
import http.cookiejar
import json
import os
import ssl
import sys
import urllib.error
import urllib.request
from pathlib import Path

HOST = os.environ.get("LMD_HOST", "192.168.254.1")
BASE = f"https://{HOST}/api/v2.0"
STATE_DIR = Path.home() / ".config" / "livemixdesktop"
COOKIE_FILE = STATE_DIR / "cookies.txt"
SENDER = "livemix-cli"

# 本体は自己署名証明書 (ATEN) なので検証しない。USB 直結の閉じたリンク前提。
_ctx = ssl.create_default_context()
_ctx.check_hostname = False
_ctx.verify_mode = ssl.CERT_NONE


class ApiError(Exception):
    def __init__(self, status, body):
        self.status, self.body = status, body
        super().__init__(f"HTTP {status}: {body}")


def _jar():
    jar = http.cookiejar.MozillaCookieJar(str(COOKIE_FILE))
    if COOKIE_FILE.exists():
        jar.load(ignore_discard=True, ignore_expires=True)
    return jar


def _save(jar):
    STATE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(STATE_DIR, 0o700)  # 本体の設定のバックアップなども置くので本人だけに
    jar.save(ignore_discard=True, ignore_expires=True)
    os.chmod(COOKIE_FILE, 0o600)


def call(method, path, body=None):
    jar = _jar()
    opener = urllib.request.build_opener(
        urllib.request.HTTPSHandler(context=_ctx),
        urllib.request.HTTPCookieProcessor(jar),
    )
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with opener.open(req, timeout=8) as r:
            raw = r.read()
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            parsed = json.loads(raw)
        except ValueError:
            parsed = raw.decode(errors="replace")
        raise ApiError(e.code, parsed) from None
    _save(jar)
    if not raw:
        return None
    try:
        return json.loads(raw)
    except ValueError:
        return raw.decode(errors="replace")


def pp(obj):
    if obj in (None, {}, ""):
        print("OK")
        return
    print(json.dumps(obj, ensure_ascii=False, indent=2) if not isinstance(obj, str) else obj)


# ---------- 認証 ----------
def cmd_login(a):
    user = os.environ.get("LMD_USER") or input("ユーザー名 [administrator]: ").strip() or "administrator"
    pw = os.environ.get("LMD_PASS") or getpass.getpass("パスワード: ")
    cred = base64.b64encode(f"{user}:{pw}".encode()).decode()
    pp(call("POST", "/auth/login", {"authorization": cred}))
    print(f"セッションを保存しました: {COOKIE_FILE}")


def cmd_logout(a):
    call("POST", "/auth/logout")
    COOKIE_FILE.unlink(missing_ok=True)
    print("ログアウトしました")


# ---------- 状態 ----------
def cmd_status(a):
    for label, path in [("system", "/system/info"), ("channels", "/channels"),
                        ("transition", "/transition"), ("transition/status", "/transition/status")]:
        print(f"== {label}")
        try:
            pp(call("GET", path))
        except ApiError as e:
            print(f"  ({e})")


# ---------- 映像スイッチング ----------
def _channel_id(name):
    """チャンネル名 (Program / Preview) から id を引く。"""
    data = call("GET", "/channels")
    for ch in data.get("channels", []):
        if ch.get("name", "").lower() == name.lower():
            return ch["id"]
    raise SystemExit(f"チャンネル {name} が見つかりません: {data}")


USER_SCENES = range(1, 9)  # 9 以降は Director / Scene Edit など OnAir の画面用


def cmd_scenes(a):
    chans = {c["sceneId"]: c["name"] for c in call("GET", "/channels")["channels"]}
    for s in call("GET", "/scenes")["scenes"]:
        if s["id"] in USER_SCENES:
            on = chans.get(s["id"], "")
            print(f'  {s["id"]}: {s["name"]:<10} layout {s["layoutId"]}  {"<- " + on if on else ""}')


def cmd_scene(channel):
    def run(a):
        if a.scene not in USER_SCENES:
            raise SystemExit("シーンは 1〜8 を指定してください")
        cid = _channel_id(channel)
        pp(call("PATCH", f"/channels/{cid}", {"sceneId": a.scene, "sender": SENDER}))
    return run


def cmd_cut(a):
    pp(call("POST", "/transition", {"mode": "cut", "sender": SENDER}))


def cmd_auto(a):
    body = {"mode": "auto", "sender": SENDER}
    if a.ms is not None:
        body["duration"] = a.ms
    pp(call("POST", "/transition", body))


def cmd_tbar(a):
    pp(call("POST", "/transition", {"mode": "manual", "position": a.position, "sender": SENDER}))


def cmd_switchmode(a):
    pp(call("PATCH", "/channels", {"switchMode": a.mode, "sender": SENDER}))


# ---------- 音声ミックス ----------
def _audio_list(kind):
    data = call("GET", f"/audio/{kind}")
    return data.get(kind, data) if isinstance(data, dict) else data


def _resolve(kind, key):
    items = _audio_list(kind)
    if key.isdigit():
        return int(key)
    k = key.lower().replace(" ", "").replace(".", "").replace("-", "")
    hits = [i for i in items if k in i.get("name", "").lower().replace(" ", "").replace(".", "").replace("-", "")]
    if len(hits) != 1:
        names = ", ".join(f'{i["id"]}:{i["name"]}' for i in items)
        raise SystemExit(f"'{key}' が一意に決まりません。候補: {names}")
    return hits[0]["id"]


def cmd_audio(a):
    for kind in ("input", "output"):
        print(f"== {kind}")
        for i in _audio_list(kind):
            gain = i.get("gain")
            db = f"{gain / 100:+.1f} dB" if isinstance(gain, int) else "?"
            pan = i.get("pan")
            pan_s = f"{pan / 100:+.0f}%" if isinstance(pan, int) else "?"
            print(f'  {i.get("id")}: {i.get("name"):<18} {db:>10}  pan {pan_s:>5}  {"MUTE" if i.get("isMute") else ""}')


def _set_audio(kind, key, **fields):
    aid = _resolve(kind, key)
    fields["sender"] = SENDER
    call("PATCH", f"/audio/{kind}/{aid}", fields)  # 非同期設定: 204 が返る
    print(f"{kind} {aid}: {fields}")


def cmd_vol(a):
    _set_audio("output" if a.output else "input", a.target, gain=round(a.db * 100))


def cmd_mute(on):
    def run(a):
        _set_audio("output" if a.output else "input", a.target, isMute=on)
    return run


def cmd_pan(a):
    _set_audio("output" if a.output else "input", a.target, pan=round(a.percent * 100))


# ---------- 調査用 ----------
def cmd_get(a):
    pp(call("GET", a.path if a.path.startswith("/") else "/" + a.path))


def main():
    p = argparse.ArgumentParser(description="GV-LSMIXER/I コントローラ")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("login").set_defaults(f=cmd_login)
    sub.add_parser("logout").set_defaults(f=cmd_logout)
    sub.add_parser("status").set_defaults(f=cmd_status)
    sub.add_parser("scenes", help="シーン一覧と PRV/PGM の割り当て").set_defaults(f=cmd_scenes)

    for name, ch in (("pgm", "Program"), ("prv", "Preview")):
        s = sub.add_parser(name, help=f"{ch} チャンネルにシーンを割り当て")
        s.add_argument("scene", type=int)
        s.set_defaults(f=cmd_scene(ch))
    sub.add_parser("cut", help="カット切替").set_defaults(f=cmd_cut)
    s = sub.add_parser("auto", help="オート切替")
    s.add_argument("ms", type=int, nargs="?")
    s.set_defaults(f=cmd_auto)
    s = sub.add_parser("tbar", help="手動トランジション位置 (255=開始, 0 で切替完了)")
    s.add_argument("position", type=int, choices=range(256), metavar="0-255")
    s.set_defaults(f=cmd_tbar)
    s = sub.add_parser("switchmode", help="本体パネルのシーンボタンの動作: 0=PRV切替 1=PGMカット 2=PGMオート")
    s.add_argument("mode", type=int, choices=(0, 1, 2))
    s.set_defaults(f=cmd_switchmode)

    sub.add_parser("audio", help="音声の入出力一覧").set_defaults(f=cmd_audio)
    for name, fn, extra in (("vol", cmd_vol, ("db", float)), ("pan", cmd_pan, ("percent", float)),
                            ("mute", cmd_mute(True), None), ("unmute", cmd_mute(False), None)):
        s = sub.add_parser(name)
        s.add_argument("target", help="名前の一部 (mic, line, hdmi1...) か id")
        if extra:
            s.add_argument(extra[0], type=extra[1])
        s.add_argument("--output", action="store_true", help="出力側を操作")
        s.set_defaults(f=fn)

    s = sub.add_parser("get", help="任意の GET (例: /source)")
    s.add_argument("path")
    s.set_defaults(f=cmd_get)

    a = p.parse_args()
    try:
        a.f(a)
    except ApiError as e:
        if e.status in (401, 403):
            print(f"認証エラー ({e.status}): {e.body}\n→ ./livemix.py login を実行してください", file=sys.stderr)
        else:
            print(e, file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f"本体に接続できません ({HOST}): {e.reason}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
