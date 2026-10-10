#!/usr/bin/env python3
"""Başlamış ve henüz bitmemiş maçların CANLI skorunu ESPN'den çekip Supabase'e yazar.

Siteyi canlı puan durumu için besler. ESPN maçı normal sürede bitti (STATUS_FULL_TIME / STATUS_FINAL)
olarak gösterince kesin skoru da yazar (bot_set_result, sadece boş skora). Uzatma/penaltılı maçların
kesin skoru update_scores.py'ye ya da yönetim sekmesine bırakılır.
Canlı alanları (live_home, live_away, live_minute, live_state), kart sayılarını ve dördüncü hakemin
gösterdiği uzatma süresini (live_added) günceller. Kartlar maç bittikten sonra da kalır.
Bitmemiş maç yoksa hiçbir ağ isteği yapmadan çıkar, yani cron'da her dakika çalıştırmak ucuzdur.

Aynı klasördeki config.json kullanılır.

Kullanım:
  python3 live_scores.py             bir kez çalışır (cron için)
  python3 live_scores.py --loop      sürekli çalışır, maç sürerken 20 saniyede bir (systemd servisi)
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


def count_cards(comp):
    """Maçtaki kartları sayar. Döndürür: (ev sarı, ev kırmızı, deplasman sarı, deplasman kırmızı)."""
    team_side = {str((x.get("team") or {}).get("id")): x["homeAway"] for x in comp["competitors"]}
    n = {"home": [0, 0], "away": [0, 0]}
    for d in comp.get("details") or []:
        side = team_side.get(str((d.get("team") or {}).get("id")))
        if side not in n:
            continue
        if d.get("redCard"):
            n[side][1] += 1
        elif d.get("yellowCard"):
            n[side][0] += 1
    return n["home"][0], n["home"][1], n["away"][0], n["away"][1]


def extract_events(comp):
    """Gol ve kart olaylarını oyuncu adıyla çıkarır.
    Döndürür: [{"k": "goal|pen|own|yellow|red", "m": "45'+2'", "p": "Oyuncu", "s": "home|away"}]"""
    team_side = {str((x.get("team") or {}).get("id")): x["homeAway"] for x in comp["competitors"]}
    out = []
    for d in comp.get("details") or []:
        if d.get("shootout"):
            continue
        side = team_side.get(str((d.get("team") or {}).get("id")))
        if side is None:
            continue
        if d.get("scoringPlay"):
            k = "own" if d.get("ownGoal") else "pen" if d.get("penaltyKick") else "goal"
        elif d.get("redCard"):
            k = "red"
        elif d.get("yellowCard"):
            k = "yellow"
        else:
            continue
        who = (d.get("athletesInvolved") or [{}])[0] or {}
        name = (who.get("displayName") or who.get("fullName") or who.get("shortName") or "")[:40]
        minute = ((d.get("clock") or {}).get("displayValue") or "")[:12]
        out.append({"k": k, "m": minute, "p": name, "s": side})
    return out[:60]


ADDED_RE = re.compile(r"announced\s+(\d+)\s+minutes?\s+of\s+added\s+time", re.I)


def announced_added(commentary, period):
    """Dördüncü hakemin bu devre için gösterdiği uzatma süresini (dakika) bulur, yoksa None.

    ESPN yorumunda "Fourth official has announced 4 minutes of added time." satırı, devrenin
    sonuna doğru (45' ya da 90' civarı) gelir. Birden fazla varsa en yenisini alırız.
    """
    prefix = {1: "45", 2: "90", 3: "105", 4: "120"}.get(period)
    if not prefix:
        return None
    best = None
    for i, c in enumerate(commentary or []):
        m = ADDED_RE.search(c.get("text") or "")
        if not m:
            continue
        shown = ((c.get("time") or {}).get("displayValue") or "")
        if not re.match(r"^%s(\D|$)" % prefix, shown):
            continue
        order = (c.get("time") or {}).get("value")
        key = (order if isinstance(order, (int, float)) else -1, c.get("sequence", i) if isinstance(c.get("sequence", i), (int, float)) else i)
        if best is None or key >= best[0]:
            best = (key, int(m.group(1)))
    return best[1] if best else None


def fetch_added(event_id, period):
    try:
        s = http_json("https://site.api.espn.com/apis/site/v2/sports/soccer/all/summary?event=%s" % event_id)
    except Exception as e:
        log("özet okunamadı (%s): %s" % (event_id, type(e).__name__))
        return None
    return announced_added(s.get("commentary"), period)


def main():
    dry = "--dry-run" in sys.argv
    cfg = load_config()
    sb = {"apikey": cfg["supabase_key"]}
    matches = http_json(cfg["supabase_url"] + "/rest/v1/matches?select=*&order=kickoff.asc", headers=sb)
    now = datetime.datetime.now(UTC)
    if dry and "--now" in sys.argv:  # deneme: "şu an" saatini ele alır, örn. --now 2026-10-09T17:30:00Z
        now = parse_utc(sys.argv[sys.argv.index("--now") + 1])

    # Kesin skoru girilmiş maçlar için de, bittikten sonra son kartların işlenmesi için 3 saat bakılır.
    cands = []
    for m in matches:
        final = m.get("home_score") is not None and m.get("away_score") is not None
        k = parse_utc(m["kickoff"])
        hi = datetime.timedelta(hours=3) if final else datetime.timedelta(hours=4, minutes=30)
        if k - datetime.timedelta(minutes=20) <= now <= k + hi:
            cands.append((m, k, final))
    if not cands:
        return False

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

    for m, k, final in cands:
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
        period = comp["status"].get("period")
        minute = norm_minute(comp["status"].get("displayClock"), period)
        cards = count_cards(comp)
        events = extract_events(comp)
        # Uzatma süresi sadece oyun sürerken okunur (devre arası ve bitişte gösterilmez).
        added = fetch_added(found["id"], period) if st == "live" else None
        old_cards = (m.get("home_yellow"), m.get("home_red"), m.get("away_yellow"), m.get("away_red"))
        extra_changed = old_cards != cards or m.get("live_added") != added
        changed = (m.get("live_home"), m.get("live_away"), m.get("live_state")) != (hs, as_, st)
        if dry:
            print("%s: %s %d-%d %s kartlar(ev sarı/kırmızı, dep sarı/kırmızı)=%s uzatma=%s %s%s" % (
                m["id"], st, hs, as_, minute, cards, added, "(skor değişti)" if changed else "", " [skor zaten kesin]" if final else ""))
            for e in events:
                print("   olay: %s %s %s (%s)" % (e["m"], e["k"], e["p"], e["s"]))
            continue
        if not final:
            r = http_json(cfg["supabase_url"] + "/rest/v1/rpc/bot_set_live", {
                "p_secret": cfg["bot_secret"], "p_id": m["id"], "p_hs": hs, "p_as": as_,
                "p_minute": minute, "p_state": st}, sb)
            if not (r and r.get("ok")):
                log("yazılamadı %s: %s" % (m["id"], r))
            elif changed:
                log("%s: %s %d-%d %s" % (m["id"], st, hs, as_, minute))
            # Normal sürede biten maçın kesin skorunu yaz. Uzatmalı/penaltılı maçlarda ESPN skoru
            # 120 dakikayı içerdiği için dokunmuyoruz (kural: 90 dk + uzatma, penaltı yok).
            if st == "ft" and comp["status"]["type"].get("name") in ("STATUS_FULL_TIME", "STATUS_FINAL"):
                r = http_json(cfg["supabase_url"] + "/rest/v1/rpc/bot_set_result", {
                    "p_secret": cfg["bot_secret"], "p_id": m["id"], "p_hs": hs, "p_as": as_}, sb)
                if r and r.get("ok"):
                    log("%s: kesin skor yazıldı %d-%d" % (m["id"], hs, as_))
                else:
                    log("kesin skor yazılamadı %s: %s" % (m["id"], r))
        if extra_changed:
            r = http_json(cfg["supabase_url"] + "/rest/v1/rpc/bot_set_extra", {
                "p_secret": cfg["bot_secret"], "p_id": m["id"], "p_hy": cards[0], "p_hr": cards[1],
                "p_ay": cards[2], "p_ar": cards[3], "p_added": added}, sb)
            if not (r and r.get("ok")):
                log("kart/uzatma yazılamadı %s: %s" % (m["id"], r))
            else:
                log("%s: kartlar=%s uzatma=%s" % (m["id"], cards, added))
        # Gol/kart olayları (oyuncu adlarıyla). events.sql çalıştırılmadıysa sütun yoktur, atlanır.
        if "live_events" in m and events != (m.get("live_events") or []):
            r = http_json(cfg["supabase_url"] + "/rest/v1/rpc/bot_set_events", {
                "p_secret": cfg["bot_secret"], "p_id": m["id"], "p_events": events}, sb)
            if not (r and r.get("ok")):
                log("olaylar yazılamadı %s: %s" % (m["id"], r))
            else:
                log("%s: %d olay yazıldı" % (m["id"], len(events)))
    return True


def run_loop():
    """Sürekli çalışır: maç sürerken 20 saniyede, maç yokken dakikada bir kontrol eder."""
    import time
    log("canlı skor servisi başladı")
    while True:
        try:
            busy = main()
        except SystemExit:
            raise
        except Exception as e:
            log("döngü hatası: %s: %s" % (type(e).__name__, e))
            busy = False
        time.sleep(20 if busy else 60)


if __name__ == "__main__":
    try:
        if "--loop" in sys.argv:
            run_loop()
        else:
            main()
    except SystemExit:
        raise
    except Exception as e:
        log("beklenmeyen hata: %s: %s" % (type(e).__name__, e))
        raise
