// Bildirimler: yeni sohbet mesajlarını ve "tahminler açıklandı" haberini bildirim açmış oyunculara Web Push ile gönderir.
// push.sql'deki tetikleyici her yeni mesajda, reveal_push.sql'deki pg_cron görevi tahminler açılınca bu fonksiyonu
// gövdesiz çağırır. Fonksiyon gelen isteğe güvenmez: gönderilmemişleri push_claim() / push_claim_reveals() ile
// kendisi alır, bu yüzden dışarıdan çağrılması zararsızdır.
// Ayarlar: "Verify JWT" kapalı. Gizliler (Edge Functions > Secrets): VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});
const VAPID_PUBLIC = Deno.env.get("VAPID_PUBLIC_KEY") || "";
const VAPID_PRIVATE = Deno.env.get("VAPID_PRIVATE_KEY") || "";
if (VAPID_PUBLIC && VAPID_PRIVATE) webpush.setVapidDetails("https://tahmin-ligi-render.onrender.com", VAPID_PUBLIC, VAPID_PRIVATE);

// deno-lint-ignore no-explicit-any
function text(m: any): string {
  const b = (m.body || "").trim();
  if (b) return b.length > 140 ? b.slice(0, 139) + "…" : b;
  if (m.image) return "📷 Fotoğraf";
  if (m.gif) return "GIF";
  return "Yeni mesaj";
}

Deno.serve(async () => {
  const [chat, rev] = await Promise.all([sb.rpc("push_claim"), sb.rpc("push_claim_reveals")]);
  // Gizliler henüz girilmediyse işaretleyip çık (sonradan eskiler topluca gitmesin).
  if (!VAPID_PUBLIC || !VAPID_PRIVATE) return Response.json({ ok: false, error: "vapid_missing" }, { status: 500 });
  if (chat.error && rev.error) return Response.json({ ok: false, error: chat.error.message }, { status: 500 });
  const msgs = chat.data || [], reveals = rev.data || [];
  if (!msgs.length && !reveals.length) return Response.json({ ok: true, sent: 0 });

  const { data: subs } = await sb.from("push_subs").select("endpoint,player_id,p256dh,auth");
  const gone = new Set<string>();
  let sent = 0;
  // deno-lint-ignore no-explicit-any
  async function sendAll(payload: string, skip: string | null) {
    // deno-lint-ignore no-explicit-any
    await Promise.all((subs || []).filter((s: any) => s.player_id !== skip && !gone.has(s.endpoint)).map(async (s: any) => {
      try {
        await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, {
          TTL: 3600,
          urgency: "high",
        });
        sent++;
      } catch (e) {
        // deno-lint-ignore no-explicit-any
        const code = (e as any)?.statusCode;
        if (code === 404 || code === 410) gone.add(s.endpoint); // abonelik geçersiz: sil
      }
    }));
  }

  // Tahminler açıldı: herkese, maç başına bir bildirim.
  for (const r of reveals) {
    await sendAll(JSON.stringify({
      title: "🔓 Tahminler açıklandı",
      body: r.home + " - " + r.away + (r.n ? " · " + r.n + " kişinin tahmini görünür oldu" : ""),
      tag: "reveal-" + r.id,
      url: "/",
    }), null);
  }
  // Sohbet: en yeniden eskiye geldi; eskiden yeniye gönder ki son bildirim en yeni mesaj olsun. Yazana gönderilmez.
  for (const m of [...msgs].reverse()) {
    await sendAll(JSON.stringify({ title: m.nick, body: text(m), tag: "chat", url: "/#sohbet" }), m.player_id);
  }
  if (gone.size) await sb.from("push_subs").delete().in("endpoint", [...gone]);
  return Response.json({ ok: true, sent });
});
