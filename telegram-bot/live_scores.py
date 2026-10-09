#!/usr/bin/env python3
"""Başlamış ve henüz bitmemiş maçların CANLI skorunu ESPN'den çekip Supabase'e yazar.

Siteyi canlı puan durumu için besler. Kesin (final) skoru yazmaz, onu update_scores.py yazar.
Sadece canlı alanları (live_home, live_away, live_minute, live_state) günceller.
Bitmemiş maç yoksa hiçbir ağ isteği yapmadan çıkar, yani cron'da her dakika çalıştırmak ucuzdur.

Aynı klasördeki config.json kullanılır.

Kullanım:
  python3 live_scores.py             normal çalışma
  python3 live_scores.py --dry-run   ne yazacağını gösterir, hiçbir şey yazmaz
"""
import datetime
import json
import os
import re
import sys
import unicodedata
import urllib.request

BASE = os.path.dirname(os.path.abspath(__file__))
LOG_FILE = os.path.join(BASE, "live.log")
SLUGS = {
    "Süper Lig": "tur.1",
    "Şampiyonlar Ligi": "uefa.champions",
    "Avrupa Ligi": "uefa.europa",
    "Konferans Ligi": "uefa.europa.conf",
}
CLUBS = ("fenerbahce", "galatasaray", "besiktas")
ESPN = "https://site.api.espn.com/apis/site/v2/sports/soccer/%s/scoreboard?dates=%s"
UTC = datetime.timezone.utc


def log(msg):
    try:
        if os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) > 200_000:
            os.replace(LOG_FILE, LOG_FILE + ".old")
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(datetime.datetime.now().isoformat(timespec="seconds") + " " + msg + "\n")
    except OSError:
        pass


def norm(s):
    s = unicodedata.normalize("NFKD", s or "")
    s = "".join(c for c in s if not unicodedata.combining(c))
    return re.sub(r"[^a-z0-9]+", " ", s.lower()).strip()


def club_of(name):
    n = norm(name)
    for c in CLUBS:
        if n == c or n.startswith(c + " "):
            return c
    return None


def load_config():
    with open(os.path.join(BASE, "config.json"), encoding="utf-8") as f:
        cfg = json.load(f)
    for k in ("supabase_url", "supabase_key", "bot_secret"):
        if not cfg.get(k) or "BURAYA" in cfg[k]:
            raise SystemExit("config.json içinde '%s' doldurulmamış." % k)
    cfg["supabase_url"] = cfg["supabase_url"].rstrip("/")
    return cfg


def http_json(url, payload=None, headers=None, timeout=20):
    h = dict(headers or {})
    data = None
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        h["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=h, method="POST" if data is not None else "GET")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8") or "null")


def parse_utc(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(UTC)


def norm_minute(clock, period):
    """ESPN'in dakikasını siteye uygun yazar: normal dakika 63', uzatma dakikası 45+2'.

    ESPN uzatmayı bazen "45'+2'" bazen sadece "47'" diye verir. Devre sınırını aşan dakikayı
    (1. yarı 45, 2. yarı 90, uzatma 105 ve 120) "sınır+fazla" biçimine çeviririz.
    """
    s = (clock or "").strip()
    m = re.match(r"^(\d+)\s*'?\s*\+\s*(\d+)\s*'?$", s)
    if m:
        return "%s+%s'" % (m.group(1), m.group(2))
    m = re.match(r"^(\d+)\s*'?$", s)
    if m:
        n = int(m.group(1))
        limit = {1: 45, 2: 90, 3: 105, 4: 120}.get(period)
        if limit and n > limit:
            return "%d+%d'" % (limit, n - limit)
        return "%d'" % n
    return s[:12]


def live_state(status):
    """ESPN durumunu 'live' | 'ht' | 'ft' | None (canlı değil) olarak çevirir."""
    t = status.get("type", {})
    name = t.get("name", "")
    state = t.get("state", "")
    if name in ("STATUS_HALFTIME", "STATUS_HALFTIME_ET"):
        return "ht"
    if state == "in":
        return "live"
    if state == "post" and name not in ("STATUS_POSTPONED", "STATUS_CANCELED", "STATUS_ABANDONED", "STATUS_FORFEIT"):
        return "ft"
    return None


def main():
    dry = "--dry-run" in sys.argv
    cfg = load_config()
    sb = {"apikey": cfg["supabase_key"]}
    matches = http_json(cfg["supabase_url"] + "/rest/v1/matches?select=*&order=kickoff.asc", headers=sb)
    now = datetime.datetime.now(UTC)
    if dry and "--now" in sys.argv:  # deneme: "şu an" saatini ele alır, örn. --now 2026-10-09T17:30:00Z
        now = parse_utc(sys.argv[sys.argv.index("--now") + 1])

    cands = []
    for m in matches:
        if m.get("home_score") is not None and m.get("away_score") is not None:
            continue
        k = parse_utc(m["kickoff"])
        if k - datetime.timedelta(minutes=20) <= now <= k + datetime.timedelta(hours=4, minutes=30):
            cands.append((m, k))
    if not cands:
        return

    cache = {}

    def board(slug, d):
        key = (slug, d)
        if key not in cache:
            try:
                cache[key] = http_json(ESPN % (slug, d)).get("events", [])
            except Exception as e:
                log("ESPN okunamadı (%s %s): %s" % (slug, d, type(e).__name__))
                cache[key] = []
        return cache[key]

    for m, k in cands:
        slug = SLUGS.get(m["comp"], "all")
        days = {(k - datetime.timedelta(days=1)).strftime("%Y%m%d"), k.strftime("%Y%m%d"), (k + datetime.timedelta(days=1)).strftime("%Y%m%d")}
        clubs = {c for c in (club_of(m["home"]), club_of(m["away"])) if c}
        found = None
        for d in sorted(days):
            for ev in board(slug, d):
                comp = ev["competitions"][0]
                ev_clubs = {c for c in (club_of(x["team"]["displayName"]) for x in comp["competitors"]) if c}
                if not (clubs & ev_clubs):
                    continue
                if abs((parse_utc(ev["date"]) - k).total_seconds()) > 3 * 3600:
                    continue
                found = ev
                break
            if found:
                break
        if not found:
            continue
        comp = found["competitions"][0]
        st = live_state(comp["status"])
        if dry:
            print("%s -> ESPN eşleşti: %s, durum=%s (%s)" % (m["id"], found.get("name"), comp["status"]["type"]["name"], st))
        if st is None:
            continue
        sides = {x["homeAway"]: x for x in comp["competitors"]}
        try:
            hs, as_ = int(sides["home"]["score"]), int(sides["away"]["score"])
        except (KeyError, ValueError, TypeError):
            continue
        minute = norm_minute(comp["status"].get("displayClock"), comp["status"].get("period"))
        changed = (m.get("live_home"), m.get("live_away"), m.get("live_state")) != (hs, as_, st)
        if dry:
            print("%s: %s %d-%d %s %s" % (m["id"], st, hs, as_, minute, "(değişti)" if changed else ""))
            continue
        r = http_json(cfg["supabase_url"] + "/rest/v1/rpc/bot_set_live", {
            "p_secret": cfg["bot_secret"], "p_id": m["id"], "p_hs": hs, "p_as": as_,
            "p_minute": minute, "p_state": st}, sb)
        if not (r and r.get("ok")):
            log("yazılamadı %s: %s" % (m["id"], r))
        elif changed:
            log("%s: %s %d-%d %s" % (m["id"], st, hs, as_, minute))


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        log("beklenmeyen hata: %s: %s" % (type(e).__name__, e))
        raise
