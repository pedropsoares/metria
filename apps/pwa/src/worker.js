import { buildPushHTTPRequest } from "@pushforge/builder";

const encoder = new TextEncoder();
const NOTIFICATION_TAG = "metria-usage";

function jsonResponse(value, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "Content-Type": "application/json" }
  });
}

function base64UrlToBytes(value) {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
  return Uint8Array.from(atob(padded), (character) => character.charCodeAt(0));
}

async function topicFor(secretBase64) {
  const secret = base64UrlToBytes(secretBase64);
  if (secret.length !== 16) throw new Error("Invalid pairing secret");
  const key = await crypto.subtle.importKey("raw", secret, "HKDF", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits(
    { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(), info: encoder.encode("metria-topic-v1") },
    key,
    128
  );
  return Array.from(new Uint8Array(bits)).map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function requestBody(request) {
  try {
    return await request.json();
  } catch {
    return null;
  }
}

async function sendPush(env, subscription, payload, topic) {
  const { endpoint, headers, body } = await buildPushHTTPRequest({
    privateJWK: JSON.parse(env.VAPID_PRIVATE_KEY),
    subscription,
    message: {
      payload,
      adminContact: env.VAPID_SUBJECT,
      options: { ttl: 86_400, urgency: "high", topic }
    }
  });
  const response = await fetch(endpoint, { method: "POST", headers, body });
  if (!response.ok) {
    const error = new Error(`Push service returned ${response.status}`);
    error.status = response.status;
    throw error;
  }
}

function usageNotification(snapshot) {
  const body = snapshot.providers
    .map((provider) => `${provider.name} ${Math.round(Number(provider.percent) || 0)}%`)
    .join(" · ");
  return { title: "AI Usage", body: body || "No provider usage available.", url: "/", tag: NOTIFICATION_TAG };
}

async function rememberTopic(env, topic) {
  const topics = String(await env.METRIA_PUSH_SUBSCRIPTIONS.get("topics") || "").split(",").filter(Boolean);
  if (!topics.includes(topic)) {
    await env.METRIA_PUSH_SUBSCRIPTIONS.put("topics", [...topics, topic].join(","));
  }
}

async function sha256Hex(value) {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(value));
  return Array.from(new Uint8Array(digest)).map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function sendUsageToTopic(env, topic, snapshot) {
  const now = Date.now();
  const subscriptionKey = `subscriptions:${topic}`;
  const subscriptions = JSON.parse((await env.METRIA_PUSH_SUBSCRIPTIONS.get(subscriptionKey)) || "[]");
  if (subscriptions.length === 0) return 0;

  // Only push when the snapshot actually changed — otherwise an unchanged snapshot
  // would keep triggering a push and a KV write indefinitely.
  const content = JSON.stringify(snapshot.providers ?? []);
  const hashKey = `pushHash:${topic}`;
  const contentHash = await sha256Hex(content);
  const lastHash = await env.METRIA_PUSH_SUBSCRIPTIONS.get(hashKey);
  if (lastHash === contentHash) return 0;

  const payload = usageNotification(snapshot);
  const results = await Promise.allSettled(subscriptions.map((subscription) => sendPush(env, subscription, payload, NOTIFICATION_TAG)));
  const activeSubscriptions = subscriptions.filter((_, index) => {
    const result = results[index];
    return result.status === "fulfilled" || ![404, 410].includes(result.reason?.status);
  });
  if (activeSubscriptions.length !== subscriptions.length) {
    await env.METRIA_PUSH_SUBSCRIPTIONS.put(subscriptionKey, JSON.stringify(activeSubscriptions));
  }
  await env.METRIA_PUSH_SUBSCRIPTIONS.put(hashKey, contentHash);
  return results.filter((result) => result.status === "fulfilled").length;
}

async function subscribe(request, env) {
  const body = await requestBody(request);
  if (!body?.secret || !body?.subscription?.endpoint || !body.subscription.keys?.auth || !body.subscription.keys?.p256dh) {
    return jsonResponse({ error: "Invalid subscription" }, 400);
  }

  const topic = await topicFor(body.secret);
  const key = `subscriptions:${topic}`;
  const subscriptions = JSON.parse((await env.METRIA_PUSH_SUBSCRIPTIONS.get(key)) || "[]");
  const updated = [...subscriptions.filter((subscription) => subscription.endpoint !== body.subscription.endpoint), body.subscription];
  await env.METRIA_PUSH_SUBSCRIPTIONS.put(key, JSON.stringify(updated));
  await rememberTopic(env, topic);
  const latestSnapshot = JSON.parse((await env.METRIA_PUSH_SUBSCRIPTIONS.get(`snapshot:${topic}`)) || "null");
  const payload = Array.isArray(latestSnapshot?.providers)
    ? usageNotification(latestSnapshot)
    : { title: "AI Usage", body: "Waiting for the latest usage from your Mac.", url: "/" };
  await sendPush(env, body.subscription, payload, NOTIFICATION_TAG);
  return jsonResponse({ ok: true });
}

async function publishUsage(request, env) {
  const body = await requestBody(request);
  if (!body?.secret || !Array.isArray(body.snapshot?.providers)) return jsonResponse({ error: "Invalid snapshot" }, 400);

  const topic = await topicFor(body.secret);
  await env.METRIA_PUSH_SUBSCRIPTIONS.put(`snapshot:${topic}`, JSON.stringify(body.snapshot));
  await rememberTopic(env, topic);
  const notifications = await sendUsageToTopic(env, topic, body.snapshot);
  return jsonResponse({ ok: true, notifications });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    try {
      if (url.pathname === "/api/push-key" && request.method === "GET") {
        return jsonResponse({ publicKey: env.VAPID_PUBLIC_KEY });
      }
      if (url.pathname === "/api/subscriptions" && request.method === "POST") {
        return subscribe(request, env);
      }
      if (url.pathname === "/api/usage" && request.method === "POST") {
        return publishUsage(request, env);
      }
      return env.ASSETS.fetch(request);
    } catch {
      return jsonResponse({ error: "Request failed" }, 500);
    }
  }
};
