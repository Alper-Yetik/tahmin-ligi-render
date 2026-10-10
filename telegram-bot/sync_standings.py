#!/usr/bin/env python3
"""Süper Lig ve Avrupa kupalarının (Şampiyonlar, Avrupa, Konferans Ligi) puan durumunu ESPN'den çekip Supabase'e yazar.

Site "Süper Lig" ve "Avrupa" sekmelerinde gösterir. ESPN'in resmi tablosu ancak maç bitince güncellenir, bu yüzden
maç sürerken (ve bitiş ile resmi tablonun güncellenmesi arasında) ligdeki canlı maçların anlık skorları resmi tablonun
üstüne uygulanır ("maç şu skorla biterse tablo böyle olur"). Canlı etkilenen takımların satırına "lv" (anlık skor) yazılır,
site onu "● CANLI" olarak gösterir. Resmi tablo maçı içerince canlı hesap kendiliğinden bırakılır.

Yetkisi sınırlı otomasyon anahtarını kullanır (bot_set_standings). Aynı klasördeki config.json kullanılır.

Kullanım:
  python3 sync_standings.py             bir kez çalışır
  python3 sync_standings.py --loop      sürekli çalışır: maç sürerken 30 sn, yokken 2 dk'da bir (systemd servisi)
  python3 sync_standings.py --dry-run   ne yazacağını gösterir, hiçbir şey yazmaz
"""
import copy
import datetime
import json
import os
import sys
import time
import urllib.request

BASE = os.path.dirname(os.path.abspath(__file__))
LOG_FILE = os.path.join(BASE, "standings.log")
UTC = datetime.timezone.utc
LEAGUES = {"super": "tur.1", "ucl": "uefa.champions", "uel": "uefa.europa", "uecl": "uefa.europa.conf"}
ESPN = "https://site.api.espn.com/apis/v2/sports/soccer/%s/standings?season=%d"
BOARD = "https://site.api.espn.com/apis/site/v2/sports/soccer/%s/scoreboard?dates=%s"  # ESPN tarih aralığına 400 verir, gün gün sorulur
SKIP_STATUS = ("STATUS_POSTPONED", "STATUS_CANCELED", "STATUS_ABANDONED", "STATUS_FORFEIT", "STATUS_SUSPENDED")
OFFICIAL_EVERY = 300  # resmi tabloyu en az bu kadar saniyede bir yenile (bekleyen maç varsa her turda)

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


def parse_utc(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(UTC)


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
    """ESPN puan durumunu sıralı satırlara çevirir: {r,t,o,w,d,l,gf,ga,gd,p,c,n} (+ iç kullanım için _i = takım kimliği)."""
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
                "gd": stat(st, "pointDifferential"), "p": stat(st, "points"), "_i": str(team.get("id")),
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


def parse_events(data, now):
    """Skor tablosundan lig maçlarını çıkarır: {id, state, h, a, hs, as, start}. Sadece oynanan/biten maçlar (state in/post)."""
    out = []
    for ev in data.get("events") or []:
        try:
            comp = ev["competitions"][0]
            t = comp["status"]["type"]
            state = t.get("state")
            if state not in ("in", "post") or t.get("name") in SKIP_STATUS:
                continue
            # Eleme turu ve eleme/play-off maçları lig tablosunu etkilemez (Süper Lig slug'ı "2026-27-turkish-super-lig").
            season_slug = str((ev.get("season") or {}).get("slug") or "").lower()
            if any(k in season_slug for k in ("knockout", "playoff", "play-off", "qualif", "round-of", "final")):
                continue
            sides = {c["homeAway"]: c for c in comp["competitors"]}
            start = parse_utc(ev["date"])
            if state == "post" and now - start > datetime.timedelta(hours=6):
                continue
            out.append({
                "id": str(ev["id"]), "state": state, "start": start,
                "h": str(sides["home"]["team"]["id"]), "a": str(sides["away"]["team"]["id"]),
                "hs": int(sides["home"]["score"]), "as": int(sides["away"]["score"]),
            })
        except (KeyError, ValueError, TypeError, IndexError):
            continue
    return out


def overlay(rows, events, base, now):
    """Resmi tablonun üstüne canlı/bitmiş-ama-henüz-işlenmemiş maçları uygular.

    base: {olay_kimliği: {"h": ev sahibi resmi oynadığı maç, "a": deplasman, "ts": ilk görülme}} (çağrılar arası korunur).
    Döndürür: (satırlar, canlı_maç_var_mı, bekleyen_maç_var_mı)
    """
    by_id = {r["_i"]: r for r in rows}
    applied, live_any = [], False
    for ev in events:
        h, a = by_id.get(ev["h"]), by_id.get(ev["a"])
        if not h or not a:
            continue
        b = base.get(ev["id"])
        if ev["state"] == "in":
            live_any = True
            if b is None:  # canlı görünce resmi tablo maçı henüz içermiyordur: oynanan maç sayılarını kaydet
                b = base[ev["id"]] = {"h": h["o"], "a": a["o"], "ts": now}
        elif b is None:
            continue  # maçın bittiği anı kaçırdık (yeniden başlatma), resmi tabloya güveniriz
        if h["o"] > b["h"] or a["o"] > b["a"]:  # resmi tablo maçı içerdi
            base.pop(ev["id"], None)
            continue
        applied.append(ev)
    for k in [k for k, v in base.items() if now - v["ts"] > datetime.timedelta(hours=8)]:
        base.pop(k, None)
    if not applied:
        return rows, live_any, bool(base)
    out = copy.deepcopy(rows)
    out_by_id = {r["_i"]: r for r in out}
    zones = [(r.get("c"), r.get("n")) for r in rows]  # renk ve açıklamalar sıraya bağlıdır, takıma değil
    for ev in applied:
        score = "%d-%d" % (ev["hs"], ev["as"])
        for tid, gf, ga in ((ev["h"], ev["hs"], ev["as"]), (ev["a"], ev["as"], ev["hs"])):
            t = out_by_id[tid]
            t["o"] += 1
            t["gf"] += gf
            t["ga"] += ga
            t["gd"] = t["gf"] - t["ga"]
            if gf > ga:
                t["w"] += 1
                t["p"] += 3
            elif gf == ga:
                t["d"] += 1
                t["p"] += 1
            else:
                t["l"] += 1
            t["lv"] = score
    order = sorted(range(len(out)), key=lambda i: (-out[i]["p"], -out[i]["gd"], -out[i]["gf"], i))
    out = [out[i] for i in order]
    for i, r in enumerate(out):
        r["r"] = i + 1
        r.pop("c", None)
        r.pop("n", None)
        if zones[i][0]:
            r["c"] = zones[i][0]
        if zones[i][1]:
            r["n"] = zones[i][1]
    return out, live_any, True


def public(rows):
    return [{k: v for k, v in r.items() if not k.startswith("_")} for r in rows]


class State:
    def __init__(self):
        self.official = {}   # lig -> (satırlar, alınma zamanı)
        self.base = {}       # lig -> overlay base
        self.written = {}    # lig -> son yazılan satırlar


def cycle(cfg, sb, st, dry):
    """Bir tur: her lig için resmi tabloyu (gerekirse) yeniler, canlı maçları uygular, değiştiyse yazar. True: canlı/bekleyen var."""
    now = datetime.datetime.now(UTC)
    year = season_year(now)
    busy = False
    day = lambda d: d.strftime("%Y%m%d")
    for league, slug in LEAGUES.items():
        base = st.base.setdefault(league, {})
        events = []
        for d in (now - datetime.timedelta(days=1), now):
            try:
                events += parse_events(http_json(BOARD % (slug, day(d))), now)
            except Exception as e:
                log("skor tablosu okunamadı (%s %s): %s %s" % (league, day(d), type(e).__name__, getattr(e, "code", "")))
        cur = st.official.get(league)
        if cur is None or base or (now - cur[1]).total_seconds() >= OFFICIAL_EVERY:
            try:
                rows = parse(http_json(ESPN % (slug, year)))
                if rows:
                    st.official[league] = cur = (rows, now)
            except Exception as e:
                log("ESPN puan durumu okunamadı (%s): %s" % (league, type(e).__name__))
        if cur is None:
            continue
        rows, live_any, pending = overlay(cur[0], events, base, now)
        busy = busy or live_any or pending
        out = public(rows)
        if dry:
            print("%s (%s %d): %d takım%s" % (league, slug, year, len(out), "  [CANLI]" if live_any else ""))
            for r in out[:4]:
                print("   %2d. %-24s O%d G%d B%d M%d AV%+d P%d %s %s" % (r["r"], r["t"], r["o"], r["w"], r["d"], r["l"], r["gd"], r["p"], r.get("n", ""), ("canlı " + r["lv"]) if r.get("lv") else ""))
            for r in out:
                if r.get("lv") and r["r"] > 4:
                    print("   %2d. %-24s P%d canlı %s" % (r["r"], r["t"], r["p"], r["lv"]))
            continue
        if st.written.get(league) == out:
            continue
        res = http_json(cfg["supabase_url"] + "/rest/v1/rpc/bot_set_standings", {
            "p_secret": cfg["bot_secret"], "p_league": league, "p_season": str(year), "p_data": out}, sb)
        if res and res.get("ok"):
            st.written[league] = out
            log("%s: puan durumu yazıldı (%d takım%s)" % (league, len(out), ", canlı" if any(r.get("lv") for r in out) else ""))
        else:
            log("%s: yazılamadı: %s" % (league, res))
    return busy


def main():
    dry = "--dry-run" in sys.argv
    cfg = None if dry else load_config()
    sb = None if dry else {"apikey": cfg["supabase_key"]}
    st = State()
    if not dry:
        try:
            for r in http_json(cfg["supabase_url"] + "/rest/v1/standings?select=league,data", headers=sb) or []:
                st.written[r["league"]] = r["data"]
        except Exception as e:
            log("mevcut tablo okunamadı (standings.sql çalıştırıldı mı?): %s" % type(e).__name__)
    if "--loop" not in sys.argv:
        cycle(cfg, sb, st, dry)
        return
    log("puan durumu servisi başladı")
    while True:
        try:
            busy = cycle(cfg, sb, st, dry)
        except SystemExit:
            raise
        except Exception as e:
            log("döngü hatası: %s: %s" % (type(e).__name__, e))
            busy = False
        time.sleep(30 if busy else 120)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        log("beklenmeyen hata: %s: %s" % (type(e).__name__, e))
        raise
