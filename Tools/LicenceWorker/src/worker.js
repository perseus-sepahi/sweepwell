// Licence service for one paid app (Cloudflare Worker). Copied from the launch-and-submit skill.
//
// GET  /claim?session_id=cs_…  Stripe sends buyers here after paying. Checks the Checkout
//                              Session with Stripe, then shows a signed licence key with an
//                              Activate button (<URL_SCHEME>://activate?key=…). Revisiting the
//                              link shows the same key: the payload and Ed25519 are deterministic.
// POST /webhook                Stripe events. A full refund or a dispute revokes the key.
// GET  /revoked                {"revoked": [purchase ids]} — the app checks it once a week.
//
// Secrets (wrangler secret put …): STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET, LICENCE_PRIVATE_KEY
// (base64 PKCS#8 from ~/.<slug>/licence-signing-key.json). Vars in wrangler.toml: PRODUCT_ID (Stripe
// product), APP_NAME, PRO_NAME, URL_SCHEME, LICENCE_PRODUCT (the "p" field the app checks), PLATFORM_NOUN.
// KV namespace REVOKED holds one entry per revoked purchase id.

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    try {
      if (request.method === "GET" && url.pathname === "/claim") return await claim(url, env);
      if (request.method === "POST" && url.pathname === "/webhook") return await webhook(request, env);
      if (request.method === "GET" && url.pathname === "/revoked") return await revoked(env);
      if (request.method === "GET" && url.pathname === "/") return page(env, `${env.APP_NAME} licences`, `<p>This service issues ${env.PRO_NAME} licence keys after purchase.</p>`);
      return new Response("Not found", { status: 404 });
    } catch (error) {
      console.error(error);
      return page(env, "Something went wrong", "<p>Please try again in a minute. If it keeps happening, write to support and include the address of this page.</p>", 500);
    }
  },
};

// MARK: Claim

async function claim(url, env) {
  const id = url.searchParams.get("session_id") || "";
  if (!/^cs_(test|live)_[A-Za-z0-9]+$/.test(id)) {
    return page(env, "Link not recognised", "<p>Open the link from your purchase confirmation again.</p>", 400);
  }
  const session = await stripe(env, `checkout/sessions/${id}?expand[]=line_items`);
  if (session.error) return page(env, "Purchase not found", "<p>Stripe doesn't know this purchase. Open the link from your confirmation again.</p>", 404);
  // A 100%-off promotion code finishes checkout with nothing to charge: "no_payment_required".
  if (session.status !== "complete" || !["paid", "no_payment_required"].includes(session.payment_status)) {
    return page(env, "Payment not finished", "<p>Your payment hasn't completed yet. Refresh this page in a minute.</p>", 402);
  }
  const items = session.line_items?.data || [];
  if (!items.some((item) => item.price?.product === env.PRODUCT_ID)) {
    return page(env, "Different product", `<p>This purchase isn't ${env.PRO_NAME}.</p>`, 400);
  }
  const purchase = session.payment_intent || session.id;
  if (await env.REVOKED.get(purchase)) {
    return page(env, "Purchase refunded", "<p>This purchase was refunded, so its licence key no longer works.</p>", 410);
  }
  const key = await licenceKey(env.LICENCE_PRIVATE_KEY, purchase, session.created, env.LICENCE_PRODUCT);
  return page(env, `Thank you for buying ${env.PRO_NAME}`, keyPage(key, env));
}

/// KGP1.<base64url payload>.<base64url Ed25519 signature over the payload text>
export async function licenceKey(privateKeyBase64, purchase, issued, product) {
  // Fixed key order keeps the payload (and so the whole key) identical on every visit.
  const payload = b64url(new TextEncoder().encode(JSON.stringify({ p: product, id: purchase, t: issued })));
  const key = await crypto.subtle.importKey("pkcs8", unb64(privateKeyBase64), { name: "Ed25519" }, false, ["sign"]);
  const signature = await crypto.subtle.sign({ name: "Ed25519" }, key, new TextEncoder().encode(payload));
  return `KGP1.${payload}.${b64url(new Uint8Array(signature))}`;
}

function keyPage(key, env) {
  const link = `${env.URL_SCHEME}://activate?key=${encodeURIComponent(key)}`;
  const device = env.PLATFORM_NOUN || "computer";
  return `
    <p>Your licence key unlocks ${env.PRO_NAME} in ${env.APP_NAME}, on any ${device} you use.</p>
    <p><a class="button" href="${link}">Activate ${env.APP_NAME} on this ${device}</a></p>
    <p class="small">Or paste the key into ${env.APP_NAME} ▸ ${env.PRO_NAME} ▸ “I already have a licence key”.</p>
    <textarea id="key" readonly rows="4" onclick="this.select()">${key}</textarea>
    <p><button onclick="navigator.clipboard.writeText(document.getElementById('key').value);this.textContent='Copied'">Copy key</button></p>
    <p class="small">Keep this key somewhere safe, or bookmark this page: it shows the same key whenever you open it.</p>`;
}

// MARK: Webhook

async function webhook(request, env) {
  const body = await request.text();
  if (!(await verifyStripeSignature(body, request.headers.get("Stripe-Signature") || "", env.STRIPE_WEBHOOK_SECRET))) {
    return new Response("Bad signature", { status: 400 });
  }
  const event = JSON.parse(body);
  const object = event.data?.object || {};
  let purchase = null;
  if (event.type === "charge.refunded" && object.refunded) purchase = object.payment_intent;
  if (event.type === "charge.dispute.created") purchase = object.payment_intent;
  if (purchase) await env.REVOKED.put(purchase, JSON.stringify({ type: event.type, at: event.created }));
  return new Response("ok");
}

/// Stripe-Signature: t=<unix>,v1=<hex HMAC-SHA256 of "t.body">; five-minute tolerance.
export async function verifyStripeSignature(body, header, secret, now = Date.now() / 1000) {
  const parts = Object.fromEntries(header.split(",").map((part) => part.split("=", 2)));
  const signatures = header.split(",").filter((part) => part.startsWith("v1=")).map((part) => part.slice(3));
  const t = Number(parts.t);
  if (!secret || !t || !signatures.length || Math.abs(now - t) > 300) return false;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${t}.${body}`)));
  const expected = [...mac].map((byte) => byte.toString(16).padStart(2, "0")).join("");
  return signatures.some((signature) => timingSafeEqual(signature, expected));
}

function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// MARK: Revoked list

async function revoked(env) {
  const ids = [];
  let cursor;
  do {
    const list = await env.REVOKED.list({ cursor });
    ids.push(...list.keys.map((entry) => entry.name));
    cursor = list.list_complete ? undefined : list.cursor;
  } while (cursor);
  return new Response(JSON.stringify({ revoked: ids }), {
    headers: { "Content-Type": "application/json", "Cache-Control": "public, max-age=3600" },
  });
}

// MARK: Helpers

async function stripe(env, path) {
  const response = await fetch(`https://api.stripe.com/v1/${path}`, {
    headers: { Authorization: `Bearer ${env.STRIPE_SECRET_KEY}` },
  });
  return response.json();
}

function b64url(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function unb64(text) {
  return Uint8Array.from(atob(text), (c) => c.charCodeAt(0));
}

function page(env, title, content, status = 200) {
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex">
<title>${title} · ${env.APP_NAME}</title>
<style>
  :root { color-scheme: light dark; --bg: #f6f5fb; --card: #fff; --text: #1d1b26; --muted: #6b6878; --accent: #7b4dff; }
  @media (prefers-color-scheme: dark) { :root { --bg: #121018; --card: #1d1a26; --text: #f1eff8; --muted: #a09cb0; } }
  body { margin: 0; background: var(--bg); color: var(--text); font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
  main { max-width: 560px; margin: 48px auto; padding: 32px; background: var(--card); border-radius: 20px; }
  h1 { font-size: 26px; margin-top: 0; }
  .button { display: inline-block; background: var(--accent); color: #fff; padding: 12px 22px; border-radius: 12px; text-decoration: none; font-weight: 600; }
  textarea { width: 100%; box-sizing: border-box; font: 13px ui-monospace, Menlo, monospace; padding: 10px; border-radius: 10px; border: 1px solid #8884; background: transparent; color: inherit; word-break: break-all; }
  button { font: inherit; padding: 8px 16px; border-radius: 10px; border: 1px solid #8886; background: transparent; color: inherit; cursor: pointer; }
  .small { color: var(--muted); font-size: 14px; }
  @media (max-width: 600px) { main { margin: 16px; padding: 22px; } }
</style></head><body><main><h1>${title}</h1>${content}</main></body></html>`;
  return new Response(html, { status, headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" } });
}
