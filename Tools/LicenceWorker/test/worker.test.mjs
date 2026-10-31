// npm test — the Worker with Stripe and KV faked (fixture values are from Kinoglot, the first app).
// The keypair below is a throwaway test key, not the real licence signing key.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createHmac, createPublicKey, verify } from "node:crypto";
import worker, { licenceKey, verifyStripeSignature } from "../src/worker.js";

const TEST_PRIVATE = "MC4CAQAwBQYDK2VwBCIEIOG/75S7kgi+uUyVQ41nd4c88ydJ6XpJeyvennTG5eom";
const TEST_PUBLIC = "LgigH1J2/SofiqCvecXEdYiRLHhg9DOf9fm24yH1AEU=";
// The app's own test should verify this same key with TEST_PUBLIC (see assets/swift/LicenceKey.swift).
const FIXTURE = "KGP1.eyJwIjoia2lub2dsb3QtcHJvIiwiaWQiOiJwaV90ZXN0MTIzIiwidCI6MTc2MTE3NzYwMH0.ba83T7KobZfC_l8mBI4rYAJSNc3rYd_sBf43-9Ca5WQoD2TqKFWhv8gNcUmwMsPrryhAnxMpjrZU9zqosk2fAQ";

function fakeKV() {
  const store = new Map();
  return {
    store,
    async get(key) { return store.get(key) ?? null; },
    async put(key, value) { store.set(key, value); },
    async list() { return { keys: [...store.keys()].map((name) => ({ name })), list_complete: true }; },
  };
}

function env(overrides = {}) {
  return {
    STRIPE_SECRET_KEY: "sk_test_fake",
    STRIPE_WEBHOOK_SECRET: "whsec_test",
    LICENCE_PRIVATE_KEY: TEST_PRIVATE,
    PRODUCT_ID: "prod_VUl84gn81ivrPu",
    APP_NAME: "Kinoglot", PRO_NAME: "Kinoglot Pro", URL_SCHEME: "kinoglot", LICENCE_PRODUCT: "kinoglot-pro", PLATFORM_NOUN: "Mac",
    REVOKED: fakeKV(),
    ...overrides,
  };
}

function stubStripe(session) {
  globalThis.fetch = async (url, init) => {
    assert.match(String(url), /^https:\/\/api\.stripe\.com\/v1\/checkout\/sessions\/cs_test_abc\?expand\[\]=line_items$/);
    assert.equal(init.headers.Authorization, "Bearer sk_test_fake");
    return new Response(JSON.stringify(session));
  };
}

const paid = {
  id: "cs_test_abc", status: "complete", payment_status: "paid", payment_intent: "pi_test123", created: 1761177600,
  line_items: { data: [{ price: { product: "prod_VUl84gn81ivrPu" } }] },
};

test("keys are deterministic, verify with Ed25519, and match the Swift fixture", async () => {
  const key = await licenceKey(TEST_PRIVATE, "pi_test123", 1761177600, "kinoglot-pro");
  assert.equal(key, await licenceKey(TEST_PRIVATE, "pi_test123", 1761177600, "kinoglot-pro"));
  assert.equal(key, FIXTURE);
  const [, payload, signature] = key.split(".");
  const publicKey = createPublicKey({ key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), Buffer.from(TEST_PUBLIC, "base64")]), format: "der", type: "spki" });
  assert.ok(verify(null, Buffer.from(payload), publicKey, Buffer.from(signature, "base64url")));
  assert.deepEqual(JSON.parse(Buffer.from(payload, "base64url")), { p: "kinoglot-pro", id: "pi_test123", t: 1761177600 });
});

test("claim shows a key and an activate link for a paid session", async () => {
  stubStripe(paid);
  const response = await worker.fetch(new Request("https://lic.example/claim?session_id=cs_test_abc"), env());
  assert.equal(response.status, 200);
  const html = await response.text();
  const key = await licenceKey(TEST_PRIVATE, "pi_test123", 1761177600, "kinoglot-pro");
  assert.ok(html.includes(key));
  assert.ok(html.includes(`kinoglot://activate?key=${encodeURIComponent(key)}`));
});

test("a 100% promotion code (nothing charged) still gets a key, tied to the session", async () => {
  stubStripe({ ...paid, payment_status: "no_payment_required", payment_intent: null });
  const response = await worker.fetch(new Request("https://lic.example/claim?session_id=cs_test_abc"), env());
  assert.equal(response.status, 200);
  assert.ok((await response.text()).includes(await licenceKey(TEST_PRIVATE, "cs_test_abc", 1761177600, "kinoglot-pro")));
});

test("claim refuses unpaid, other products, refunded and malformed links", async () => {
  stubStripe({ ...paid, status: "open", payment_status: "unpaid" });
  assert.equal((await worker.fetch(new Request("https://lic.example/claim?session_id=cs_test_abc"), env())).status, 402);

  stubStripe({ ...paid, payment_status: "unpaid" });
  assert.equal((await worker.fetch(new Request("https://lic.example/claim?session_id=cs_test_abc"), env())).status, 402);

  stubStripe({ ...paid, line_items: { data: [{ price: { product: "prod_other" } }] } });
  assert.equal((await worker.fetch(new Request("https://lic.example/claim?session_id=cs_test_abc"), env())).status, 400);

  stubStripe(paid);
  const refunded = env();
  await refunded.REVOKED.put("pi_test123", "{}");
  assert.equal((await worker.fetch(new Request("https://lic.example/claim?session_id=cs_test_abc"), refunded)).status, 410);

  globalThis.fetch = async () => assert.fail("must not call Stripe");
  assert.equal((await worker.fetch(new Request("https://lic.example/claim?session_id=../../balance"), env())).status, 400);
});

function signed(body, secret = "whsec_test", t = Math.floor(Date.now() / 1000)) {
  return `t=${t},v1=${createHmac("sha256", secret).update(`${t}.${body}`).digest("hex")}`;
}

test("webhook revokes full refunds and disputes, ignores partial refunds and bad signatures", async () => {
  const e = env();
  const send = (event, header) => {
    const body = JSON.stringify(event);
    return worker.fetch(new Request("https://lic.example/webhook", { method: "POST", body, headers: { "Stripe-Signature": header ?? signed(body) } }), e);
  };
  const partial = { type: "charge.refunded", created: 1, data: { object: { refunded: false, payment_intent: "pi_partial" } } };
  assert.equal((await send(partial)).status, 200);
  assert.equal(e.REVOKED.store.has("pi_partial"), false);

  const full = { type: "charge.refunded", created: 2, data: { object: { refunded: true, payment_intent: "pi_full" } } };
  assert.equal((await send(full, signed(JSON.stringify(full), "whsec_wrong"))).status, 400);
  assert.equal(e.REVOKED.store.has("pi_full"), false);
  assert.equal((await send(full)).status, 200);

  const dispute = { type: "charge.dispute.created", created: 3, data: { object: { payment_intent: "pi_dispute" } } };
  assert.equal((await send(dispute)).status, 200);

  const list = await (await worker.fetch(new Request("https://lic.example/revoked"), e)).json();
  assert.deepEqual(list.revoked.sort(), ["pi_dispute", "pi_full"]);
});

test("stripe signatures expire after five minutes", async () => {
  const body = "{}";
  const old = Math.floor(Date.now() / 1000) - 600;
  assert.equal(await verifyStripeSignature(body, signed(body, "whsec_test", old), "whsec_test"), false);
  assert.equal(await verifyStripeSignature(body, signed(body), "whsec_test"), true);
});
