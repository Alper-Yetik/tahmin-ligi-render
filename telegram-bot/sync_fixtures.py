#!/usr/bin/env python3
"""Fenerbahçe, Galatasaray ve Beşiktaş'ın yeni maçlarını ESPN'den çekip Supabase'e ekler.

Sadece maç ekler ve henüz skoru olmayan gelecekteki bir maçın saati değiştiyse saatini günceller.
Skorlara, silmeye ve oyuncu verisine dokunmaz. Yetkisi sınırlı otomasyon anahtarını kullanır.

Aynı klasördeki config.json kullanılır (bot.py ile aynı).

Kullanım:
  python3 sync_fixtures.py             normal çalışma
  python3 sync_fixtures.py --dry-run   ne yapacağını yazar, hiçbir şey eklemez
"""
import datetime
import json
import os
import re
import sys
import unicodedata
import urllib.error
import urllib.request

BASE = os.path.dirname(os.path.abspath(__file__))
LOG_FILE = os.path.join(BASE, "fixtures.log")
WINDOW_DAYS = 75  # bugünden bu kadar gün sonrasına kadar olan maçları ekle
CLUBS = {"fb": ("Fenerbahçe", 436), "gs": ("Galatasaray", 432), "bjk": ("Beşiktaş", 1895)}
ESPN = "https://site.api.espn.com/apis/site/v2/sports/soccer/all/teams/%d/schedule?fixture=true"
TR = datetime.timezone(datetime.timedelta(hours=3))

# ESPN'in İngilizce harfli adlarını sitedeki yazıma çevirir. Listede olmayan takım ESPN'deki adıyla eklenir.
NAMES = {
    "Fenerbahce": "Fenerbahçe", "Besiktas": "Beşiktaş", "Kasimpasa": "Kasımpaşa",
    "Genclerbirligi": "Gençlerbirliği", "Caykur Rizespor": "Çaykur Rizespor", "Goztepe": "Göztepe",
    "Istanbul Basaksehir": "İstanbul Başakşehir", "Eyupspor": "Eyüpspor", "Karagumruk": "Fatih Karagümrük",
    "Fatih Karagumruk": "Fatih Karagümrük", "Corum FK": "Çorum FK", "TSG Hoffenheim": "Hoffenheim",
    "Hapoel Be'er": "Hapoel Beer Sheva", "Hapoel Beer Sheva": "Hapoel Beer Sheva",
}


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
    for key, (label, _id) in CLUBS.items():
        if norm(label) == n or (n.startswith(norm(label)) and len(n) < len(norm(label)) + 4):
            return key
    return None


def tr_name(espn_name):
    return NAMES.get(espn_name, espn_name)


def comp_of(league):
    slug = (league.get("slug") or "").lower()
    name = (league.get("name") or "").lower()
    if slug == "tur.1" or "super lig" in name:
        return "Süper Lig"
    if "champions" in name:
        return "Şampiyonlar Ligi"
    if "conference" in name:
        return "Konferans Ligi"
    if "europa" in name:
        return "Avrupa Ligi"
    if "super cup" in name:
        return "Süper Kupa"
    if "turkish cup" in name or "ziraat" in name or slug == "tur.cup":
        return "Türkiye Kupası"
    return None


def load_config():
    with open(os.path.join(BASE, "config.json"), encoding="utf-8") as f:
        cfg = json.load(f)
    for k in ("supabase_url", "supabase_key", "bot_secret"):
        if not cfg.get(k) or "BURAYA" in cfg[k]:
            raise SystemExit("config.json içinde '%s' doldurulmamış." % k)
    cfg["supabase_url"] = cfg["supabase_url"].rstrip("/")
    return cfg


def http_json(url, payload=None, headers=None):
    h = dict(headers or {})
    data = None
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        h["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=h, method="POST" if data is not None else "GET")
    with urllib.request.urlopen(req, timeout=25) as r:
        return json.loads(r.read().decode("utf-8") or "null")


def parse_utc(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(datetime.timezone.utc)


def day_key(dt_utc):
    return dt_utc.astimezone(TR).strftime("%Y%m%d")


def main():
    dry = "--dry-run" in sys.argv
    cfg = load_config()
    sb_headers = {"apikey": cfg["supabase_key"]}

    existing = http_json(cfg["supabase_url"] + "/rest/v1/matches?select=*&order=kickoff.asc", headers=sb_headers)
    by_slot = {}  # (kulüp, gün) -> maç
    ids = set()
    for m in existing:
        ids.add(m["id"])
        k = parse_utc(m["kickoff"])
        for side in (m["home"], m["away"]):
            c = club_of(side)
            if c:
                by_slot[(c, day_key(k))] = m

    now = datetime.datetime.now(datetime.timezone.utc)
    limit = now + datetime.timedelta(days=WINDOW_DAYS)
    seen = set()
    added = changed = skipped = 0

    for ckey, (label, tid) in CLUBS.items():
        try:
            data = http_json(ESPN % tid)
        except Exception as e:
            log("ESPN okunamadı (%s): %s" % (label, type(e).__name__))
            continue
        for ev in data.get("events", []):
            comp = ev["competitions"][0]
            if comp["status"]["type"]["name"] != "STATUS_SCHEDULED":
                continue
            kick = parse_utc(ev["date"])
            if kick <= now or kick > limit:
                continue
            league = comp_of(ev.get("league") or {})
            if not league:
                log("tanınmayan organizasyon atlandı: %s" % (ev.get("league") or {}).get("name"))
                skipped += 1
                continue
            sides = {c["homeAway"]: c["team"]["displayName"] for c in comp["competitors"]}
            if "home" not in sides or "away" not in sides:
                continue
            home, away = tr_name(sides["home"]), tr_name(sides["away"])
            clubs = [c for c in (club_of(home), club_of(away)) if c]
            if not clubs:
                continue
            slots = [(c, day_key(kick)) for c in clubs]
            if any(s in seen for s in slots):
                continue  # derbi: diğer takımın programında zaten işlendi
            seen.update(slots)

            found = next((by_slot[s] for s in slots if s in by_slot), None)
            if found:
                old = parse_utc(found["kickoff"])
                no_score = found.get("home_score") is None and found.get("away_score") is None
                if old != kick and no_score and old > now:
                    msg = "saat güncellendi: %s - %s  %s -> %s" % (found["home"], found["away"], old.isoformat(), kick.isoformat())
                    log(msg)
                    print(msg)
                    if not dry:
                        r = http_json(cfg["supabase_url"] + "/rest/v1/rpc/bot_upsert_match", {
                            "p_secret": cfg["bot_secret"], "p_id": found["id"], "p_home": found["home"],
                            "p_away": found["away"], "p_comp": found["comp"], "p_kickoff": kick.isoformat()},
                            sb_headers)
                        if not (r and r.get("ok")):
                            log("güncelleme reddedildi: %s" % r)
                            continue
                    changed += 1
                continue

            first = clubs[0]
            other = away if clubs[0] == club_of(home) else home
            slug = norm(other).replace(" ", "")[:20] or "mac"
            mid = "%s-%s-%s" % (first, day_key(kick), slug)
            n = 2
            while mid in ids:
                mid = "%s-%s-%s-%d" % (first, day_key(kick), slug, n)
                n += 1
            ids.add(mid)
            msg = "eklenecek: %s | %s - %s | %s | %s" % (mid, home, away, league, kick.astimezone(TR).strftime("%d.%m.%Y %H:%M TSİ"))
            print(msg)
            log(msg)
            if not dry:
                r = http_json(cfg["supabase_url"] + "/rest/v1/rpc/bot_upsert_match", {
                    "p_secret": cfg["bot_secret"], "p_id": mid, "p_home": home, "p_away": away,
                    "p_comp": league, "p_kickoff": kick.isoformat()}, sb_headers)
                if not (r and r.get("ok")):
                    log("ekleme reddedildi: %s" % r)
                    continue
            added += 1

    summary = "%s: %d maç eklendi, %d saati güncellendi, %d atlandı" % ("DENEME" if dry else "tamam", added, changed, skipped)
    print(summary)
    if added or changed or dry:
        log(summary)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        log("beklenmeyen hata: %s: %s" % (type(e).__name__, e))
        raise
