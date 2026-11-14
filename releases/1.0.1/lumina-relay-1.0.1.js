var __defProp = Object.defineProperty;
var __name = (target, value) => __defProp(target, "name", { value, configurable: true });

// src/crypto.ts
var encoder = new TextEncoder();
var HKDF_INFO = encoder.encode("lumina-pair-v1");
function toBase64Url(bytes) {
  const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let binary = "";
  for (const b of view) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
__name(toBase64Url, "toBase64Url");
function fromBase64Url(text) {
  const binary = atob(text.replace(/-/g, "+").replace(/_/g, "/"));
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}
__name(fromBase64Url, "fromBase64Url");
function randomToken(byteLength = 32) {
  return toBase64Url(crypto.getRandomValues(new Uint8Array(byteLength)));
}
__name(randomToken, "randomToken");
async function sha256Hex(text) {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(text)));
  return Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join("");
}
__name(sha256Hex, "sha256Hex");
function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
__name(timingSafeEqual, "timingSafeEqual");
var CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
var CODE_LENGTH = 6;
function randomPairingCode() {
  const bytes = crypto.getRandomValues(new Uint8Array(CODE_LENGTH));
  return Array.from(bytes, (b) => CODE_ALPHABET[b & 31]).join("");
}
__name(randomPairingCode, "randomPairingCode");
function normalizePairingCode(input) {
  const code = (input ?? "").replace(/[\s-]/g, "").toUpperCase();
  if (code.length !== CODE_LENGTH) return null;
  for (const ch of code) if (!CODE_ALPHABET.includes(ch)) return null;
  return code;
}
__name(normalizePairingCode, "normalizePairingCode");
async function deriveKey(privateKey, publicKey, usage) {
  const shared = await crypto.subtle.deriveBits({ name: "ECDH", public: publicKey }, privateKey, 256);
  const hkdf = await crypto.subtle.importKey("raw", shared, "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: HKDF_INFO },
    hkdf,
    { name: "AES-GCM", length: 256 },
    false,
    [usage]
  );
}
__name(deriveKey, "deriveKey");
function importPublicKey(rawBase64Url) {
  return crypto.subtle.importKey(
    "raw",
    fromBase64Url(rawBase64Url),
    { name: "ECDH", namedCurve: "P-256" },
    false,
    []
  );
}
__name(importPublicKey, "importPublicKey");
async function seal(recipientPublicKeyRaw, plaintext) {
  const recipient = await importPublicKey(recipientPublicKeyRaw);
  const ephemeral = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, [
    "deriveBits"
  ]);
  const key = await deriveKey(ephemeral.privateKey, recipient, "encrypt");
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, encoder.encode(plaintext));
  const epk = await crypto.subtle.exportKey("raw", ephemeral.publicKey);
  return { epk: toBase64Url(epk), iv: toBase64Url(iv), ct: toBase64Url(ct) };
}
__name(seal, "seal");
async function pkceChallenge(verifier) {
  return toBase64Url(await crypto.subtle.digest("SHA-256", encoder.encode(verifier)));
}
__name(pkceChallenge, "pkceChallenge");

// src/media.ts
var DRIVE_FILES = "https://www.googleapis.com/drive/v3/files/";
var MAX_TICKET_SECONDS = 3600;
var FILE_ID = /^[A-Za-z0-9_-]{10,200}$/;
async function ticketKey(secret) {
  const raw = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(secret));
  return crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt", "decrypt"]);
}
__name(ticketKey, "ticketKey");
async function makeTicket(secret, body) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv },
    await ticketKey(secret),
    new TextEncoder().encode(JSON.stringify(body))
  );
  return `${toBase64Url(iv)}.${toBase64Url(ct)}`;
}
__name(makeTicket, "makeTicket");
async function readTicket(secret, ticket, now = Date.now()) {
  const [iv, ct] = ticket.split(".");
  if (!iv || !ct || ticket.length > 4096) return null;
  try {
    const plain = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: fromBase64Url(iv) },
      await ticketKey(secret),
      fromBase64Url(ct)
    );
    const body = JSON.parse(new TextDecoder().decode(plain));
    if (typeof body.t !== "string" || typeof body.f !== "string" || typeof body.e !== "number") return null;
    if (now > body.e) return null;
    return body;
  } catch {
    return null;
  }
}
__name(readTicket, "readTicket");
var API_HEADERS = {
  "Cache-Control": "no-store",
  "Content-Type": "application/json; charset=utf-8",
  "Access-Control-Allow-Origin": "*",
  "X-Content-Type-Options": "nosniff"
};
var json = /* @__PURE__ */ __name((body, status = 200) => new Response(JSON.stringify(body), { status, headers: API_HEADERS }), "json");
async function issueTicket(body, origin, env, fetcher, now = Date.now()) {
  if (!env.TICKET_KEY) return json({ error: "not_configured" }, 503);
  const token = typeof body?.access_token === "string" ? body.access_token : "";
  const fileId = typeof body?.file_id === "string" ? body.file_id : "";
  if (!token || !FILE_ID.test(fileId)) return json({ error: "bad_request" }, 400);
  let meta;
  try {
    meta = await fetcher(`${DRIVE_FILES}${fileId}?fields=id,mimeType,size&supportsAllDrives=true`, {
      headers: { Authorization: `Bearer ${token}` }
    });
  } catch {
    return json({ error: "upstream_unreachable" }, 502);
  }
  if (meta.status === 401) return json({ error: "invalid_token" }, 401);
  if (meta.status === 403 || meta.status === 404) return json({ error: "no_access" }, 403);
  if (!meta.ok) return json({ error: "upstream_error" }, 502);
  const info = await meta.json().catch(() => ({}));
  const requested = typeof body?.expires_at === "number" ? body.expires_at : Infinity;
  const expiresAt = Math.min(now + MAX_TICKET_SECONDS * 1e3, requested);
  if (expiresAt <= now) return json({ error: "invalid_token" }, 401);
  const ticket = await makeTicket(env.TICKET_KEY, { t: token, f: fileId, e: expiresAt });
  return json({ url: `${origin}/media/${ticket}`, expiresAt, mimeType: info.mimeType ?? "" });
}
__name(issueTicket, "issueTicket");
var PASS_THROUGH = ["content-type", "content-length", "content-range", "accept-ranges", "etag", "last-modified"];
async function streamMedia(request, ticket, env, fetcher, now = Date.now()) {
  const plain = { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" };
  if (!env.TICKET_KEY) return new Response("not configured", { status: 503, headers: plain });
  const body = await readTicket(env.TICKET_KEY, ticket, now);
  if (!body) return new Response("link expired", { status: 403, headers: plain });
  const headers = { Authorization: `Bearer ${body.t}` };
  const range = request.headers.get("Range");
  if (range && /^bytes=\d*-\d*(,\s*\d*-\d*)*$/.test(range)) headers.Range = range;
  const ifRange = request.headers.get("If-Range");
  if (ifRange && range) headers["If-Range"] = ifRange;
  let upstream;
  try {
    upstream = await fetcher(`${DRIVE_FILES}${body.f}?alt=media&supportsAllDrives=true`, {
      method: "GET",
      headers
    });
  } catch {
    return new Response("upstream unreachable", { status: 502, headers: plain });
  }
  if (!upstream.ok && upstream.status !== 206) {
    await upstream.body?.cancel();
    const status = upstream.status === 416 ? 416 : upstream.status === 401 ? 403 : upstream.status === 404 ? 404 : 502;
    return new Response(null, { status, headers: plain });
  }
  const out = new Headers(plain);
  for (const name of PASS_THROUGH) {
    const value = upstream.headers.get(name);
    if (value) out.set(name, value);
  }
  if (!out.has("accept-ranges")) out.set("Accept-Ranges", "bytes");
  if (request.method === "HEAD") {
    await upstream.body?.cancel();
    return new Response(null, { status: upstream.status, headers: out });
  }
  return new Response(upstream.body, { status: upstream.status, headers: out });
}
__name(streamMedia, "streamMedia");

// src/pages.ts
var escapeHtml = /* @__PURE__ */ __name((s) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`), "escapeHtml");
var formatCode = /* @__PURE__ */ __name((code) => `${code.slice(0, 3)}-${code.slice(3)}`, "formatCode");
function layout(title, body) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>${escapeHtml(title)}</title>
<style>
  :root { color-scheme: dark; }
  body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: #000; color: #f5f5f7;
         font: 500 17px/1.45 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
  main { width: min(92vw, 420px); padding: 32px 0; }
  h1 { font-size: 28px; line-height: 1.15; letter-spacing: -0.02em; margin: 0 0 12px; }
  p { margin: 0 0 16px; color: rgba(245,245,247,.72); }
  .code { font: 600 40px/1 ui-monospace, Menlo, Consolas, monospace; letter-spacing: .08em; color: #f5f5f7;
          padding: 20px; margin: 20px 0; border-radius: 20px; background: #141416; border: 1px solid rgba(255,255,255,.08); text-align: center; }
  .button { display: block; text-align: center; padding: 16px 20px; border-radius: 999px; background: #f5f5f7; color: #000;
            font-weight: 600; text-decoration: none; border: 0; width: 100%; font-size: 17px; box-sizing: border-box; }
  input { width: 100%; box-sizing: border-box; padding: 16px; margin: 0 0 16px; border-radius: 14px; border: 1px solid rgba(255,255,255,.16);
          background: #141416; color: #f5f5f7; font: 600 24px ui-monospace, Menlo, Consolas, monospace; text-align: center; text-transform: uppercase; }
  .note { font-size: 14px; color: rgba(245,245,247,.5); margin-top: 20px; }
</style>
</head>
<body><main>${body}</main></body>
</html>`;
}
__name(layout, "layout");
function confirmPage(code) {
  return layout(
    "Connect Lumina",
    `<h1>Connect Lumina to Google Drive</h1>
<p>Check that your TV is showing this code:</p>
<div class="code">${escapeHtml(formatCode(code))}</div>
<p>Only continue if this is your TV. Whoever is showing this code will be able to view your Google Drive files.</p>
<a class="button" href="/auth/start?code=${encodeURIComponent(code)}">Continue with Google</a>
<p class="note">Lumina asks for read-only access to Drive, plus your name, email and profile picture to show which account is connected.</p>`
  );
}
__name(confirmPage, "confirmPage");
function enterCodePage(message = "") {
  return layout(
    "Connect Lumina",
    `<h1>Enter the code on your TV</h1>
${message ? `<p>${escapeHtml(message)}</p>` : "<p>Open Lumina on your TV and choose Connect. It shows a six-character code.</p>"}
<form method="get" action="/pair">
<input name="code" autocomplete="off" autocapitalize="characters" spellcheck="false" maxlength="7" placeholder="ABC-234" aria-label="Pairing code" required>
<button class="button" type="submit">Continue</button>
</form>`
  );
}
__name(enterCodePage, "enterCodePage");
function messagePage(title, message) {
  return layout(title, `<h1>${escapeHtml(title)}</h1><p>${escapeHtml(message)}</p>`);
}
__name(messagePage, "messagePage");

// src/worker.ts
var GOOGLE_AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth";
var GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token";
var GOOGLE_REVOKE_URL = "https://oauth2.googleapis.com/revoke";
var SCOPES = "openid email profile https://www.googleapis.com/auth/drive.readonly";
var PAIRING_TTL_SECONDS = 600;
var POLL_INTERVAL_SECONDS = 3;
var MAX_BODY_BYTES = 8 * 1024;
var NO_STORE = { "Cache-Control": "no-store" };
var API_HEADERS2 = {
  ...NO_STORE,
  "Content-Type": "application/json; charset=utf-8",
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
  "Access-Control-Max-Age": "86400",
  "X-Content-Type-Options": "nosniff"
};
var PAGE_HEADERS = {
  ...NO_STORE,
  "Content-Type": "text/html; charset=utf-8",
  "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
  "Referrer-Policy": "no-referrer",
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "DENY"
};
var json2 = /* @__PURE__ */ __name((body, status = 200) => new Response(JSON.stringify(body), { status, headers: API_HEADERS2 }), "json");
var page = /* @__PURE__ */ __name((html, status = 200) => new Response(html, { status, headers: PAGE_HEADERS }), "page");
var pairKey = /* @__PURE__ */ __name((code) => `pair:${code}`, "pairKey");
var stateKey = /* @__PURE__ */ __name((state) => `state:${state}`, "stateKey");
async function readJson(request) {
  const text = await request.text();
  if (text.length > MAX_BODY_BYTES) return null;
  try {
    const value = JSON.parse(text);
    return value && typeof value === "object" && !Array.isArray(value) ? value : null;
  } catch {
    return null;
  }
}
__name(readJson, "readJson");
async function allowed(limiter, request, bucket) {
  if (!limiter) return true;
  const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
  const { success } = await limiter.limit({ key: `${bucket}:${ip}` });
  return success;
}
__name(allowed, "allowed");
async function getRecord(kv, key) {
  const raw = await kv.get(key);
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}
__name(getRecord, "getRecord");
function profileFromIdToken(idToken) {
  const empty = { name: "", email: "", picture: "" };
  if (typeof idToken !== "string") return empty;
  try {
    const payload = idToken.split(".")[1] ?? "";
    const jsonText = new TextDecoder().decode(
      Uint8Array.from(atob(payload.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0))
    );
    const claims = JSON.parse(jsonText);
    const str = /* @__PURE__ */ __name((v) => typeof v === "string" ? v : "", "str");
    return { name: str(claims.name), email: str(claims.email), picture: str(claims.picture) };
  } catch {
    return empty;
  }
}
__name(profileFromIdToken, "profileFromIdToken");
async function pairStart(request, env) {
  if (!await allowed(env.RL_STRICT, request, "start")) return json2({ error: "rate_limited" }, 429);
  const body = await readJson(request);
  const publicKey = typeof body?.publicKey === "string" ? body.publicKey : "";
  try {
    await importPublicKey(publicKey);
  } catch {
    return json2({ error: "invalid_public_key" }, 400);
  }
  const secret = randomToken();
  const record = { secretHash: await sha256Hex(secret), publicKey, status: "pending" };
  let code = "";
  for (let attempt = 0; attempt < 5; attempt++) {
    const candidate = randomPairingCode();
    if (await env.PAIRINGS.get(pairKey(candidate)) === null) {
      code = candidate;
      break;
    }
  }
  if (!code) return json2({ error: "try_again" }, 503);
  await env.PAIRINGS.put(pairKey(code), JSON.stringify(record), { expirationTtl: PAIRING_TTL_SECONDS });
  const origin = new URL(request.url).origin;
  return json2({
    code,
    secret,
    verifyUrl: `${origin}/pair?code=${code}`,
    shortUrl: `${origin}/pair`,
    expiresIn: PAIRING_TTL_SECONDS,
    interval: POLL_INTERVAL_SECONDS
  });
}
__name(pairStart, "pairStart");
async function pairPoll(request, env) {
  if (!await allowed(env.RL_POLL, request, "poll")) return json2({ error: "rate_limited" }, 429);
  const body = await readJson(request);
  const code = normalizePairingCode(typeof body?.code === "string" ? body.code : null);
  const secret = typeof body?.secret === "string" ? body.secret : "";
  if (!code || !secret) return json2({ error: "bad_request" }, 400);
  const record = await getRecord(env.PAIRINGS, pairKey(code));
  if (!record) return json2({ status: "expired" }, 404);
  if (!timingSafeEqual(await sha256Hex(secret), record.secretHash)) {
    return json2({ error: "forbidden" }, 403);
  }
  if (record.status === "pending") return json2({ status: "pending" });
  await env.PAIRINGS.delete(pairKey(code));
  if (record.status === "denied" || !record.sealed) return json2({ status: "denied" });
  return json2({ status: "ready", sealed: record.sealed });
}
__name(pairPoll, "pairPoll");
async function refresh(request, env, fetcher) {
  if (!await allowed(env.RL_POLL, request, "refresh")) return json2({ error: "rate_limited" }, 429);
  const body = await readJson(request);
  const refreshToken = typeof body?.refresh_token === "string" ? body.refresh_token : "";
  if (!refreshToken) return json2({ error: "bad_request" }, 400);
  let response;
  try {
    response = await fetcher(GOOGLE_TOKEN_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        client_id: env.GOOGLE_CLIENT_ID,
        client_secret: env.GOOGLE_CLIENT_SECRET,
        grant_type: "refresh_token",
        refresh_token: refreshToken
      }).toString()
    });
  } catch {
    return json2({ error: "upstream_unreachable" }, 502);
  }
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    if (data.error === "invalid_grant") return json2({ error: "invalid_grant" }, 401);
    return json2({ error: "upstream_error" }, 502);
  }
  if (typeof data.access_token !== "string") return json2({ error: "upstream_error" }, 502);
  return json2({
    access_token: data.access_token,
    expires_in: typeof data.expires_in === "number" ? data.expires_in : 3600
  });
}
__name(refresh, "refresh");
async function revoke(request, env, fetcher) {
  if (!await allowed(env.RL_POLL, request, "revoke")) return json2({ error: "rate_limited" }, 429);
  const body = await readJson(request);
  const token = typeof body?.token === "string" ? body.token : "";
  if (!token) return json2({ error: "bad_request" }, 400);
  let revoked = false;
  try {
    const response = await fetcher(GOOGLE_REVOKE_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ token }).toString()
    });
    revoked = response.ok;
  } catch {
    revoked = false;
  }
  return json2({ revoked });
}
__name(revoke, "revoke");
async function pairPage(url, env) {
  const raw = url.searchParams.get("code");
  if (raw === null) return page(enterCodePage());
  const code = normalizePairingCode(raw);
  const record = code ? await getRecord(env.PAIRINGS, pairKey(code)) : null;
  if (!code || !record || record.status !== "pending") {
    return page(enterCodePage("That code was not found or has expired. Check the code on your TV."), 404);
  }
  return page(confirmPage(code));
}
__name(pairPage, "pairPage");
async function authStart(request, url, env) {
  if (!await allowed(env.RL_STRICT, request, "auth")) {
    return page(messagePage("Too many attempts", "Please wait a minute and try again."), 429);
  }
  const code = normalizePairingCode(url.searchParams.get("code"));
  const record = code ? await getRecord(env.PAIRINGS, pairKey(code)) : null;
  if (!code || !record || record.status !== "pending") {
    return page(enterCodePage("That code was not found or has expired. Check the code on your TV."), 404);
  }
  const state = randomToken();
  const verifier = randomToken(48);
  const stateRecord = { code, verifier };
  await env.PAIRINGS.put(stateKey(state), JSON.stringify(stateRecord), {
    expirationTtl: PAIRING_TTL_SECONDS
  });
  const target = new URL(GOOGLE_AUTH_URL);
  target.search = new URLSearchParams({
    client_id: env.GOOGLE_CLIENT_ID,
    redirect_uri: `${url.origin}/auth/callback`,
    response_type: "code",
    scope: SCOPES,
    // offline + consent: Google only returns a refresh token on a consented grant.
    access_type: "offline",
    prompt: "consent",
    state,
    code_challenge: await pkceChallenge(verifier),
    code_challenge_method: "S256"
  }).toString();
  return new Response(null, { status: 302, headers: { ...NO_STORE, Location: target.toString() } });
}
__name(authStart, "authStart");
async function authCallback(url, env, fetcher) {
  const state = url.searchParams.get("state") ?? "";
  const stateRecord = state ? await getRecord(env.PAIRINGS, stateKey(state)) : null;
  if (!stateRecord) {
    return page(
      messagePage("This link has expired", "Start again from the code shown on your TV."),
      400
    );
  }
  await env.PAIRINGS.delete(stateKey(state));
  const pairing = await getRecord(env.PAIRINGS, pairKey(stateRecord.code));
  if (!pairing || pairing.status !== "pending") {
    return page(messagePage("This code has expired", "Start again from your TV."), 400);
  }
  const finish = /* @__PURE__ */ __name(async (update) => env.PAIRINGS.put(pairKey(stateRecord.code), JSON.stringify({ ...pairing, ...update }), {
    // Long enough for the TV's next poll; never extends past the original window by much.
    expirationTtl: 120
  }), "finish");
  const authCode = url.searchParams.get("code");
  if (url.searchParams.get("error") || !authCode) {
    await finish({ status: "denied" });
    return page(messagePage("Not connected", "Access was not granted. You can try again from your TV."));
  }
  let response;
  try {
    response = await fetcher(GOOGLE_TOKEN_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        client_id: env.GOOGLE_CLIENT_ID,
        client_secret: env.GOOGLE_CLIENT_SECRET,
        code: authCode,
        code_verifier: stateRecord.verifier,
        grant_type: "authorization_code",
        redirect_uri: `${url.origin}/auth/callback`
      }).toString()
    });
  } catch {
    return page(messagePage("Something went wrong", "Google could not be reached. Try again from your TV."), 502);
  }
  const data = await response.json().catch(() => ({}));
  if (!response.ok || typeof data.access_token !== "string" || typeof data.refresh_token !== "string") {
    await finish({ status: "denied" });
    return page(messagePage("Something went wrong", "Sign-in did not complete. Try again from your TV."), 502);
  }
  const sealed = await seal(
    pairing.publicKey,
    JSON.stringify({
      access_token: data.access_token,
      refresh_token: data.refresh_token,
      expires_in: typeof data.expires_in === "number" ? data.expires_in : 3600,
      scope: typeof data.scope === "string" ? data.scope : "",
      profile: profileFromIdToken(data.id_token)
    })
  );
  await finish({ status: "ready", sealed });
  return page(messagePage("Connected", "You can put your phone down. Your TV will continue in a few seconds."));
}
__name(authCallback, "authCallback");
async function handle(request, env, fetcher = fetch) {
  const url = new URL(request.url);
  const route = `${request.method} ${url.pathname}`;
  if ((request.method === "GET" || request.method === "HEAD") && url.pathname.startsWith("/media/")) {
    if (!await allowed(env.RL_MEDIA, request, "media")) {
      return new Response("rate limited", { status: 429, headers: NO_STORE });
    }
    try {
      return await streamMedia(request, url.pathname.slice("/media/".length), env, fetcher);
    } catch {
      return new Response("error", { status: 500, headers: NO_STORE });
    }
  }
  if (request.method === "OPTIONS" && url.pathname.startsWith("/api/")) {
    return new Response(null, { status: 204, headers: API_HEADERS2 });
  }
  try {
    switch (route) {
      case "POST /api/pair/start":
        return await pairStart(request, env);
      case "POST /api/pair/poll":
        return await pairPoll(request, env);
      case "POST /api/refresh":
        return await refresh(request, env, fetcher);
      case "POST /api/revoke":
        return await revoke(request, env, fetcher);
      case "POST /api/media/ticket":
        if (!await allowed(env.RL_POLL, request, "ticket")) return json2({ error: "rate_limited" }, 429);
        return await issueTicket(await readJson(request), url.origin, env, fetcher);
      case "GET /pair":
        return await pairPage(url, env);
      case "GET /auth/start":
        return await authStart(request, url, env);
      case "GET /auth/callback":
        return await authCallback(url, env, fetcher);
      case "GET /":
        return page(enterCodePage());
      default:
        return url.pathname.startsWith("/api/") ? json2({ error: "not_found" }, 404) : page(messagePage("Not found", "There is nothing at this address."), 404);
    }
  } catch {
    return url.pathname.startsWith("/api/") ? json2({ error: "internal_error" }, 500) : page(messagePage("Something went wrong", "Please try again from your TV."), 500);
  }
}
__name(handle, "handle");
var worker_default = {
  fetch: /* @__PURE__ */ __name((request, env) => handle(request, env), "fetch")
};
export {
  PAIRING_TTL_SECONDS,
  POLL_INTERVAL_SECONDS,
  SCOPES,
  worker_default as default,
  handle
};
//# sourceMappingURL=worker.js.map
