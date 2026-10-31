# Licence service (Cloudflare Worker)

Turns a Stripe Checkout payment into an offline-verifiable Ed25519 licence key, and lists refunded purchases.

| Route | What it does |
|---|---|
| `GET /claim?session_id=cs_…` | Stripe redirects buyers here. Checks the session is complete and paid (or `no_payment_required` for 100%-off codes) and is for `PRODUCT_ID`, then shows the key and an Activate button. Same key on every visit. |
| `POST /webhook` | Stripe events, signature-checked. `charge.refunded` (full) and `charge.dispute.created` revoke the purchase. |
| `GET /revoked` | `{"revoked": [...]}` — the app checks weekly; network failure never locks a payer out. |

Key format: `KGP1.<base64url JSON {"p": LICENCE_PRODUCT, "id": purchase, "t": unix}>.<base64url Ed25519 signature over the payload text>`. The purchase id is the PaymentIntent, or the Checkout Session for free (100%) orders.

## Set-up (the owner runs the account steps)

1. `node keygen.mjs <slug>` → public key into the app; private key stays in `~/.<slug>/`.
2. Fill `wrangler.toml`. `npx wrangler login` (the owner signs in), `npx wrangler kv namespace create REVOKED`.
3. `npx wrangler secret put STRIPE_SECRET_KEY` (restricted key, read access to Checkout Sessions), `LICENCE_PRIVATE_KEY` (the `privateKeyPKCS8` value), `STRIPE_WEBHOOK_SECRET` (step 6).
4. `npm test`, then `npx wrangler deploy` → `https://<slug>-licence.<account>.workers.dev`.
5. Stripe payment link → After payment → redirect to `<address>/claim?session_id={CHECKOUT_SESSION_ID}`; allow promotion codes.
6. Stripe → Developers → Webhooks → `<address>/webhook` for `charge.refunded`, `charge.dispute.created`.

Secrets are typed by the owner into wrangler's prompt; they never go in files, commits or chat.
