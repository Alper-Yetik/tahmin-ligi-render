// Sohbet bildirimi: yeni sohbet mesajlarını bildirim açmış oyunculara Web Push ile gönderir.
// push.sql'deki tetikleyici her yeni mesajda bu fonksiyonu gövdesiz çağırır. Fonksiyon gelen isteğe güvenmez:
// gönderilmemiş mesajları push_claim() ile kendisi alır, bu yüzden dışarıdan çağrılması zararsızdır.
// Ayarlar: "Verify JWT" kapalı. Gizliler (Edge Functions > Secrets): VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});
webpush.setVapidDetails(
  "https://tahmin-ligi-render.onrender.com",
  Deno.env.get("VAPID_PUBLIC_KEY")!,
  Deno.env.get("VAPID_PRIVATE_KEY")!,
);

// deno-lint-ignore no-explicit-any
function text(m: any): string {
  const b = (m.body || "").trim();
  if (b) return b.length > 140 ? b.slice(0, 139) + "…" : b;
  if (m.image) return "📷 Fotoğraf";
  if (m.gif) return "GIF";
  return "Yeni mesaj";
}

Deno.serve(async () => {
  const { data: msgs, error } = await sb.rpc("push_claim");
  if (error) return Response.json({ ok: false, error: error.message }, { status: 500 });
  if (!msgs || !msgs.length) return Response.json({ ok: true, sent: 0 });

  const { data: subs } = await sb.from("push_subs").select("endpoint,player_id,p256dh,auth");
  const gone = new Set<string>();
  let sent = 0;
  // En yeniden eskiye geldi; eskiden yeniye gönder ki son bildirim en yeni mesaj olsun.
  for (const m of [...msgs].reverse()) {
    const payload = JSON.stringify({ title: m.nick, body: text(m), tag: "chat", url: "/#sohbet" });
    // deno-lint-ignore no-explicit-any
    await Promise.all((subs || []).filter((s: any) => s.player_id !== m.player_id && !gone.has(s.endpoint)).map(async (s: any) => {
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
  if (gone.size) await sb.from("push_subs").delete().in("endpoint", [...gone]);
  return Response.json({ ok: true, sent });
});
