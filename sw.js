/* Servis çalışanı: sohbet bildirimlerini gösterir (Web Push). Sayfa önbelleği tutmaz, site her zaman güncel yüklenir. */
self.addEventListener("install", function () { self.skipWaiting(); });
self.addEventListener("activate", function (e) { e.waitUntil(self.clients.claim()); });

self.addEventListener("push", function (e) {
  var d = {};
  try { d = e.data ? e.data.json() : {}; } catch (x) { d = { body: e.data ? e.data.text() : "" }; }
  e.waitUntil(self.registration.showNotification(d.title || "Üçlü Tahmin Ligi", {
    body: d.body || "Yeni mesaj",
    icon: "/icons/icon-192.png",
    badge: "/icons/icon-192.png",
    tag: d.tag || "chat",
    renotify: true,
    data: { url: d.url || "/#sohbet" }
  }));
});

/* Bildirime dokununca: açık pencere varsa öne getirip sohbeti açar, yoksa siteyi sohbet açık başlatır. */
self.addEventListener("notificationclick", function (e) {
  e.notification.close();
  var url = (e.notification.data && e.notification.data.url) || "/#sohbet";
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(function (list) {
    for (var i = 0; i < list.length; i++) {
      if ("focus" in list[i]) { list[i].postMessage({ type: "openChat" }); return list[i].focus(); }
    }
    return self.clients.openWindow(url);
  }));
});
