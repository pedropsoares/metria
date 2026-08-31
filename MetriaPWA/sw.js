// This name is fixed on purpose — do not bump it on every deploy. Because the fetch
// handler below is network-first, freshness never depends on the cache name changing;
// it only exists so the cache has a stable place to live and so the `activate` cleanup
// below can sweep out old-named caches left over from versions before this comment.
const CACHE_NAME = "metria-pwa-v3";
const NOTIFICATION_TAG = "metria-usage";
const ASSETS = ["./", "./index.html", "./app.css", "./app.js", "./pairing.js", "./wordlist.js", "./scanner.js", "./jsQR.js", "./manifest.json", "./icon.svg", "./metria-logo.png", "./metria-mascot.png"];

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.addAll(ASSETS)));
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((names) => Promise.all(names.filter((name) => name !== CACHE_NAME).map((name) => caches.delete(name))))
      .then(() => self.clients.claim())
  );
});

// Network-first: always tries to fetch the latest version first, falling back to the
// cache only when offline. This prevents stale JS/CSS from getting stuck on a device
// after a deploy, which previously kept an outdated ntfy endpoint cached indefinitely.
self.addEventListener("fetch", (event) => {
  if (new URL(event.request.url).origin !== self.location.origin || event.request.method !== "GET") return;
  event.respondWith(
    fetch(event.request)
      .then((response) => {
        if (response.ok) {
          const clone = response.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(event.request, clone));
        }
        return response;
      })
      .catch(() => caches.match(event.request))
  );
});

self.addEventListener("push", (event) => {
  const payload = event.data?.json() || { title: "AI Usage", body: "Your usage has changed.", url: "/" };
  event.waitUntil((async () => {
    const existingNotifications = await self.registration.getNotifications({ tag: NOTIFICATION_TAG });
    existingNotifications.forEach((notification) => notification.close());
    await self.registration.showNotification(payload.title, {
      body: payload.body,
      data: { url: payload.url },
      tag: NOTIFICATION_TAG
    });
  })());
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  event.waitUntil(clients.openWindow(event.notification.data.url));
});
