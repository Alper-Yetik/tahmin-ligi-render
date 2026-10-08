#!/usr/bin/env python3
"""Üçlü Tahmin Ligi Telegram botu.

Her çalışışında iki iş yapar:
  1. Bota gelen /start mesajlarını okur ve oyuncuyu Telegram sohbetine bağlar.
  2. Tahmin kapanışına az kalmış maçlar için, tahmin girmemiş ve Telegram'ı bağlamış oyunculara özel mesaj atar.

Sadece Python standart kütüphanesini kullanır. cron ile 2 dakikada bir çalıştırılır.
Gizli bilgiler (bot anahtarı vb.) aynı klasördeki config.json dosyasında durur, GitHub'a konmaz.

Kullanım:
  python3 bot.py           normal çalışma
  python3 bot.py --check   bağlantıları dener, mesaj göndermez
"""
import datetime
import json
import os
import re
import sys
import urllib.error
import urllib.request

BASE = os.path.dirname(os.path.abspath(__file__))
STATE_FILE = os.path.join(BASE, "state.json")
LOG_FILE = os.path.join(BASE, "bot.log")
SITE_URL = "https://tahmin-ligi-render.onrender.com/"
REMIND_HOURS = 3  # tahmin kapanışına bu kadar saat kala hatırlat (maçtan 8 saat önce)
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
TR = datetime.timezone(datetime.timedelta(hours=3))


def log(msg):
    try:
        if os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) > 200_000:
            os.replace(LOG_FILE, LOG_FILE + ".old")
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(datetime.datetime.now().isoformat(timespec="seconds") + " " + msg + "\n")
    except OSError:
        pass


def load_config():
    with open(os.path.join(BASE, "config.json"), encoding="utf-8") as f:
        cfg = json.load(f)
    for k in ("telegram_token", "supabase_url", "supabase_key", "bot_secret"):
        if not cfg.get(k) or "BURAYA" in cfg[k]:
            raise SystemExit("config.json içinde '%s' doldurulmamış." % k)
    cfg["supabase_url"] = cfg["supabase_url"].rstrip("/")
    return cfg


def post_json(url, payload, headers=None):
    data = json.dumps(payload).encode("utf-8")
    h = {"Content-Type": "application/json"}
    h.update(headers or {})
    req = urllib.request.Request(url, data=data, headers=h, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, json.loads(r.read().decode("utf-8") or "null")
    except urllib.error.HTTPError as e:
        try:
            body = json.loads(e.read().decode("utf-8") or "null")
        except Exception:
            body = None
        return e.code, body


class Bot:
    def __init__(self, cfg):
        self.cfg = cfg
        self.tg_url = "https://api.telegram.org/bot" + cfg["telegram_token"]

    def tg(self, method, payload=None):
        return post_json(self.tg_url + "/" + method, payload or {})

    def rpc(self, name, args):
        args = dict(args)
        args["p_secret"] = self.cfg["bot_secret"]
        headers = {"apikey": self.cfg["supabase_key"]}
        status, body = post_json(self.cfg["supabase_url"] + "/rest/v1/rpc/" + name, args, headers)
        return status, body

    def send(self, chat_id, text):
        return self.tg("sendMessage", {"chat_id": chat_id, "text": text, "disable_web_page_preview": True})


def load_state():
    try:
        with open(STATE_FILE, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"offset": 0}


def save_state(st):
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(st, f)
    os.replace(tmp, STATE_FILE)


def handle_updates(bot):
    st = load_state()
    status, res = bot.tg("getUpdates", {"offset": st.get("offset", 0), "timeout": 0, "allowed_updates": ["message"]})
    if status != 200 or not res or not res.get("ok"):
        log("getUpdates hata: %s" % status)
        return
    for u in res["result"]:
        st["offset"] = u["update_id"] + 1
        msg = u.get("message") or {}
        text = (msg.get("text") or "").strip()
        chat = (msg.get("chat") or {}).get("id")
        if chat is None or not text.startswith("/start"):
            save_state(st)
            continue
        parts = text.split(maxsplit=1)
        payload = parts[1].strip() if len(parts) > 1 else ""
        if UUID_RE.match(payload):
            s, r = bot.rpc("bot_link_telegram", {"p_player": payload, "p_chat": chat})
            if s == 200 and r and r.get("ok"):
                bot.send(chat, "Bağlandı, %s. Tahmin girmediğin maçlarda, tahmin kapanışına %d saat kala sana buradan hatırlatma göndereceğim." % (r.get("nick", ""), REMIND_HOURS))
                log("bağlandı: %s" % r.get("nick"))
            else:
                bot.send(chat, "Bağlanamadı. Siteyi açıp adını yazdıktan sonra 'Telegram'dan hatırlat' bağlantısına tekrar tıkla: " + SITE_URL)
                log("bağlama hatası: %s %s" % (s, r))
        else:
            bot.send(chat, "Merhaba! Hatırlatma almak için siteyi aç, adını yaz ve 'Telegram'dan hatırlat' bağlantısına tıkla: " + SITE_URL)
        save_state(st)
    save_state(st)


def fmt_close(iso):
    dt = datetime.datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone(TR)
    return dt.strftime("%d.%m %H:%M")


def handle_due(bot):
    s, r = bot.rpc("bot_telegram_due", {"p_hours": REMIND_HOURS})
    if s != 200 or not r or not r.get("ok"):
        log("due hata: %s %s" % (s, r))
        return
    for it in r.get("items", []):
        text = (
            "%s, %s – %s (%s) maçı için henüz tahmin girmedin.\n"
            "Tahmin kapanışı: %s (Türkiye saati). Kapanınca giriş yapılamaz.\n%s"
            % (it["nick"], it["home"], it["away"], it["comp"], fmt_close(it["close_at"]), SITE_URL)
        )
        ts, tr = bot.send(it["chat_id"], text)
        # 403: kullanıcı botu engellemiş. Sonsuza kadar denemesin diye işaretle.
        if ts == 200 or ts == 403:
            bot.rpc("bot_telegram_mark", {"p_match": it["match_id"], "p_player": it["player_id"]})
            log("hatırlatma %s: %s %s" % ("gönderildi" if ts == 200 else "engelli", it["nick"], it["match_id"]))
        else:
            log("gönderilemedi (%s): %s %s" % (ts, it["nick"], it["match_id"]))


def check(bot):
    s, r = bot.tg("getMe")
    print("Telegram:", "tamam, @%s" % r["result"]["username"] if s == 200 and r and r.get("ok") else "HATA %s" % s)
    s, r = bot.rpc("bot_telegram_due", {"p_hours": REMIND_HOURS})
    if s == 200 and r and r.get("ok"):
        print("Supabase: tamam, şu an gönderilecek hatırlatma sayısı: %d" % len(r.get("items", [])))
    else:
        print("Supabase: HATA", s, r)


def main():
    bot = Bot(load_config())
    if "--check" in sys.argv:
        check(bot)
        return
    handle_updates(bot)
    handle_due(bot)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:  # cron'da sessizce ölmesin
        log("beklenmeyen hata: %s: %s" % (type(e).__name__, e))
        raise
