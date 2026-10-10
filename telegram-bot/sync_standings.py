#!/usr/bin/env python3
"""Süper Lig ve Avrupa kupalarının (Şampiyonlar, Avrupa, Konferans Ligi) puan durumunu ESPN'den çekip Supabase'e yazar.

Site "Süper Lig" ve "Avrupa" sekmelerinde gösterir. Sadece değişen tabloyu yazar. Yetkisi sınırlı otomasyon anahtarını
kullanır (bot_set_standings). Aynı klasördeki config.json kullanılır.

Kullanım:
  python3 sync_standings.py             normal çalışma (cron: saatte bir)
  python3 sync_standings.py --dry-run   ne yazacağını gösterir, hiçbir şey yazmaz
"""
import datetime
import json
import os
import sys
import urllib.request

BASE = os.path.dirname(os.path.abspath(__file__))
LOG_FILE = os.path.join(BASE, "standings.log")
LEAGUES = {"super": "tur.1", "ucl": "uefa.champions", "uel": "uefa.europa", "uecl": "uefa.europa.conf"}
ESPN = "https://site.api.espn.com/apis/v2/sports/soccer/%s/standings?season=%d"

# ESPN'in İngilizce harfli adlarını sitedeki yazıma çevirir. Listede olmayan takım ESPN'deki adıyla yazılır.
NAMES = {
    "Fenerbahce": "Fenerbahçe", "Besiktas": "Beşiktaş", "Kasimpasa": "Kasımpaşa",
    "Genclerbirligi": "Gençlerbirliği", "Caykur Rizespor": "Çaykur Rizespor", "Goztepe": "Göztepe",
    "Istanbul Basaksehir": "İstanbul Başakşehir", "Eyupspor": "Eyüpspor", "Karagumruk": "Fatih Karagümrük",
    "Fatih Karagumruk": "Fatih Karagümrük", "Corum FK": "Çorum FK", "TSG Hoffenheim": "Hoffenheim",
}


def log(msg):
    try:
        if os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) > 100_000:
            os.replace(LOG_FILE, LOG_FILE + ".old")
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(datetime.datetime.now().isoformat(timespec="seconds") + " " + msg + "\n")
    except OSError:
        pass


def load_config():
    with open(os.path.join(BASE, "config.json"), encoding="utf-8") as f:
        cfg = json.load(f)
    for k in ("supabase_url", "supabase_key", "bot_secret"):
        if not cfg.get(k) or "BURAYA" in cfg[k]:
            raise SystemExit("config.json içinde '%s' doldurulmamış." % k)
    cfg["supabase_url"] = cfg["supabase_url"].rstrip("/")
    return cfg


def http_json(url, payload=None, headers=None, timeout=25):
    h = {"User-Agent": "Mozilla/5.0 tahmin-ligi"}
    h.update(headers or {})
    data = None
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        h["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=h, method="POST" if data is not None else "GET")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8") or "null")


def season_year(now):
    """Sezon yılı: Temmuz'dan itibaren yeni sezon (2026-27 sezonu için 2026)."""
    return now.year if now.month >= 7 else now.year - 1


def stat(stats, name):
    for s in stats or []:
        if s.get("name") == name:
            v = s.get("value")
            return int(v) if isinstance(v, (int, float)) else 0
    return 0


def parse(data):
    """ESPN puan durumunu [{r,t,o,w,d,l,gf,ga,gd,p,c,n}] biçimine çevirir (sıraya göre)."""
    rows = []
    for child in data.get("children") or []:
        for e in (child.get("standings") or {}).get("entries") or []:
            team = e.get("team") or {}
            name = team.get("displayName") or team.get("name") or ""
            st = e.get("stats") or []
            note = e.get("note") or {}
            row = {
                "r": stat(st, "rank"), "t": NAMES.get(name, name)[:40], "o": stat(st, "gamesPlayed"),
                "w": stat(st, "wins"), "d": stat(st, "ties"), "l": stat(st, "losses"),
                "gf": stat(st, "pointsFor"), "ga": stat(st, "pointsAgainst"),
                "gd": stat(st, "pointDifferential"), "p": stat(st, "points"),
            }
            color = str(note.get("color") or "")
            if len(color) == 7 and color.startswith("#"):
                row["c"] = color
            if note.get("description"):
                row["n"] = str(note["description"])[:60]
            rows.append(row)
        if rows:  # ilk grubu al (lig usulü kupalarda tek tablo var)
            break
    rows.sort(key=lambda x: (x["r"] or 999, -x["p"]))
    return rows[:80]


def main():
    dry = "--dry-run" in sys.argv
    cfg = None if dry else load_config()
    sb = None if dry else {"apikey": cfg["supabase_key"]}
    now = datetime.datetime.now(datetime.timezone.utc)
    year = season_year(now)
    old = {}
    if not dry:
        try:
            for r in http_json(cfg["supabase_url"] + "/rest/v1/standings?select=league,data", headers=sb) or []:
                old[r["league"]] = r["data"]
        except Exception as e:
            log("mevcut tablo okunamadı (standings.sql çalıştırıldı mı?): %s" % type(e).__name__)
    for league, slug in LEAGUES.items():
        try:
            rows = parse(http_json(ESPN % (slug, year)))
        except Exception as e:
            log("ESPN okunamadı (%s): %s" % (league, type(e).__name__))
            continue
        if not rows:
            log("%s: boş tablo, yazılmadı" % league)
            continue
        if dry:
            print("%s (%s %d): %d takım" % (league, slug, year, len(rows)))
            for r in rows[:4]:
                print("   %2d. %-24s O%d G%d B%d M%d AV%+d P%d  %s" % (r["r"], r["t"], r["o"], r["w"], r["d"], r["l"], r["gd"], r["p"], r.get("n", "")))
            continue
        if old.get(league) == rows:
            continue
        r = http_json(cfg["supabase_url"] + "/rest/v1/rpc/bot_set_standings", {
            "p_secret": cfg["bot_secret"], "p_league": league, "p_season": str(year), "p_data": rows}, sb)
        if r and r.get("ok"):
            log("%s: puan durumu yazıldı (%d takım)" % (league, len(rows)))
        else:
            log("%s: yazılamadı: %s" % (league, r))


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        log("beklenmeyen hata: %s: %s" % (type(e).__name__, e))
        raise
