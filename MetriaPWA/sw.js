// This name is fixed on purpose — do not bump it on every deploy. Because the fetch
// handler below is network-first, freshness never depends on the cache name changing;
// it only exists so the cache has a stable place to live and so the `activate` cleanup
// below can sweep out old-named caches left over from versions before this comment.
const CACHE_NAME = "metria-pwa";
const ASSETS = ["./", "./index.html", "./app.css", "./app.js", "./pairing.js", "./wordlist.js", "./scanner.js", "./jsQR.js", "./manifest.json"];

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
  if (new URL(event.request.url).origin !== self.location.origin) return;
  event.respondWith(
    fetch(event.request)
      .then((response) => {
        const clone = response.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(event.request, clone));
        return response;
      })
      .catch(() => caches.match(event.request))
  );
});
