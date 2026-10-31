#!/usr/bin/env python3
"""One discount code for every edition of a paid app.

The same code string (e.g. LAUNCH50) is created as:
  - an App Store offer code (custom code) on the app's non-consumable in-app purchase, which
    covers the Mac, iPhone and iPad App Store builds (universal purchase), and
  - a Stripe promotion code on the app's Stripe product, which covers every direct-download
    build (Developer ID Mac, Windows, Linux, sideloaded Android) that sells through the payment link.

Usage
  discount_codes.py plan   --config launch.json --code LAUNCH50 --percent 50 (--expires 2026-12-31 | --no-expiry) [--max 500 | --unlimited]
  discount_codes.py create ...same flags... [--only apple|stripe] --apply

`plan` (and `create` without --apply) touches no network. `create --apply` makes the codes.
Standard library + the `openssl` command only. Secrets are read locally and never printed:
  Apple: the App Store Connect API key .p8 file named in the config.
  Stripe: the macOS Keychain item named in the config (owner adds it with
          `security add-generic-password -a "$USER" -s <service> -w`, which prompts), or $STRIPE_SECRET_KEY.

launch.json (in the app's working folder; holds no secrets):
  {
    "app": "Kinoglot", "full_price": "2.99",
    "apple":  {"bundle_id": "com.example.App", "iap_product_id": "com.example.App.pro",
               "issuer_id": "<uuid>", "key_id": "<10 chars>", "key_path": "~/.appstoreconnect/AuthKey_XXXX.p8"},
    "stripe": {"product_id": "prod_...", "keychain_service": "stripe-secret-key-<slug>"}
  }
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from decimal import Decimal
from zoneinfo import ZoneInfo

PACIFIC = ZoneInfo("America/Los_Angeles")  # Apple expires offer codes at midnight Pacific
APPLE_MAX_REDEMPTIONS = 25_000              # Apple's ceiling for one custom code
APPLE_ONE_TIME_MAX_DAYS = 183               # one-time-use codes: "up to 6 months"
STRIPE_VERSION = "2024-06-20"               # pinned: promotion codes take `coupon` in this version


class Problem(Exception):
    pass


# MARK: Validation and planning (pure, unit-tested)

def validate(code: str, percent: int, expires: dt.date | None, max_redemptions: int | None,
             today: dt.date | None = None) -> list[str]:
    today = today or dt.datetime.now(PACIFIC).date()
    issues = []
    if not re.fullmatch(r"[A-Za-z0-9]{1,64}", code or ""):
        issues.append("The code must be 1-64 letters and digits only (no spaces or symbols), so every store accepts it.")
    if not 10 <= percent <= 100:
        issues.append("The discount must be between 10% and 100%.")
    if expires is not None and expires <= today:
        issues.append("The expiry date must be after today.")
    if max_redemptions is not None and max_redemptions < 1:
        issues.append("The redemption limit must be at least 1.")
    return issues


def notes(percent: int, expires: dt.date | None, max_redemptions: int | None, today: dt.date | None = None) -> list[str]:
    """Honest per-store differences, shown before anything is created."""
    today = today or dt.datetime.now(PACIFIC).date()
    out = []
    if max_redemptions is None or max_redemptions > APPLE_MAX_REDEMPTIONS:
        out.append(f"App Store: a custom code allows at most {APPLE_MAX_REDEMPTIONS:,} redemptions, so 'unlimited' becomes {APPLE_MAX_REDEMPTIONS:,} there (Stripe stays unlimited).")
    if expires is not None and (expires - today).days > APPLE_ONE_TIME_MAX_DAYS:
        out.append("App Store: if Apple refuses an expiry this far out, rerun with --only apple and an earlier date or --no-expiry.")
    if percent < 100:
        out.append("App Store: prices snap to Apple's price points, so the real discount can differ by a few percent (shown below once connected).")
    out.append("App Store: codes start working only after the in-app purchase is approved; customers redeem in the App Store, by link, or with the app's Redeem Code button.")
    out.append("Stripe: the payment link must have 'Allow promotion codes' on. Codes are case-insensitive at checkout.")
    return out


def target_price(full: Decimal, percent: int) -> Decimal:
    return max(Decimal(0), full * (100 - percent) / 100)


def pick_price_point(points: list[dict], full: Decimal, percent: int) -> dict | None:
    """points: [{"id", "territory", "price": Decimal}]. Closest to target, below full; 100% needs a 0.00 point."""
    if percent >= 100:
        return next((p for p in points if p["price"] == 0), None)
    target = target_price(full, percent)
    candidates = [p for p in points if 0 < p["price"] < full]
    if not candidates:
        return None
    return min(candidates, key=lambda p: (abs(p["price"] - target), p["price"]))


def actual_percent(price: Decimal, full: Decimal) -> int:
    return int(((full - price) / full * 100).quantize(Decimal(1))) if full > 0 else 0


def stripe_expiry(expires: dt.date) -> int:
    """End of the expiry day in Pacific time, so both stores stop on the same day."""
    end = dt.datetime.combine(expires, dt.time(23, 59, 59), tzinfo=PACIFIC)
    return int(end.timestamp())


def apple_offer_body(name: str, iap_id: str, prices: list[dict]) -> dict:
    ref = lambda p: f"${{price-{p['territory']}}}"
    return {
        "data": {
            "type": "inAppPurchaseOfferCodes",
            "attributes": {"name": name, "customerEligibilities": ["NON_SPENDER", "ACTIVE_SPENDER", "CHURNED_SPENDER"]},
            "relationships": {
                "inAppPurchase": {"data": {"type": "inAppPurchases", "id": iap_id}},
                "prices": {"data": [{"type": "inAppPurchaseOfferPrices", "id": ref(p)} for p in prices]},
            },
        },
        "included": [{
            "type": "inAppPurchaseOfferPrices", "id": ref(p),
            "relationships": {
                "territory": {"data": {"type": "territories", "id": p["territory"]}},
                "pricePoint": {"data": {"type": "inAppPurchasePricePoints", "id": p["id"]}},
            },
        } for p in prices],
    }


def apple_custom_code_body(offer_id: str, code: str, limit: int, expires: dt.date | None) -> dict:
    attributes = {"customCode": code.upper(), "numberOfCodes": limit}
    if expires is not None:
        attributes["expirationDate"] = expires.isoformat()
    return {"data": {"type": "inAppPurchaseOfferCodeCustomCodes", "attributes": attributes,
                     "relationships": {"offerCode": {"data": {"type": "inAppPurchaseOfferCodes", "id": offer_id}}}}}


def stripe_coupon_params(code: str, percent: int, product_id: str) -> dict:
    return {"percent_off": str(percent), "duration": "once", "name": f"{code.upper()} ({percent}% off)",
            "applies_to[products][0]": product_id}


def stripe_promotion_params(code: str, coupon_id: str, expires: dt.date | None, max_redemptions: int | None) -> dict:
    params = {"code": code.upper(), "coupon": coupon_id}
    if expires is not None:
        params["expires_at"] = str(stripe_expiry(expires))
    if max_redemptions is not None:
        params["max_redemptions"] = str(max_redemptions)
    return params


# MARK: ES256 for the App Store Connect API (openssl does the signing)

def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(der: bytes, size: int = 32) -> bytes:
    """ECDSA DER signature (SEQUENCE{INTEGER r, INTEGER s}) → raw r‖s as JWS ES256 wants."""
    if der[0] != 0x30:
        raise Problem("Unexpected signature format from openssl.")
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    out = b""
    for _ in range(2):
        if der[i] != 0x02:
            raise Problem("Unexpected signature format from openssl.")
        n = der[i + 1]
        value = der[i + 2:i + 2 + n].lstrip(b"\x00")
        out += value.rjust(size, b"\x00")
        i += 2 + n
    return out


def apple_token(issuer_id: str, key_id: str, key_path: str, now: int | None = None) -> str:
    now = now or int(time.time())
    head = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}, separators=(",", ":")).encode())
    body = b64url(json.dumps({"iss": issuer_id, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
                             separators=(",", ":")).encode())
    signing_input = f"{head}.{body}".encode()
    with tempfile.NamedTemporaryFile() as message:
        message.write(signing_input)
        message.flush()
        result = subprocess.run(["openssl", "dgst", "-sha256", "-sign", os.path.expanduser(key_path), message.name],
                                capture_output=True)
    if result.returncode != 0:
        raise Problem("openssl couldn't sign with the App Store Connect key. Check key_path in launch.json.")
    return f"{head}.{body}.{b64url(der_to_raw(result.stdout))}"


# MARK: Network

def http(method: str, url: str, headers: dict, body: bytes | None = None) -> dict:
    request = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            data = response.read()
            return json.loads(data) if data else {}
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")[:600]
        try:
            parsed = json.loads(detail)
            if "errors" in parsed:  # App Store Connect
                detail = " · ".join(e.get("detail") or e.get("title", "") for e in parsed["errors"])
            elif "error" in parsed:  # Stripe
                detail = parsed["error"].get("message", detail)
        except ValueError:
            pass
        raise Problem(f"{urllib.parse.urlsplit(url).netloc} said {error.code}: {detail}") from None


class Apple:
    base = "https://api.appstoreconnect.apple.com"

    def __init__(self, cfg: dict):
        self.cfg = cfg

    def call(self, method: str, path: str, query: dict | None = None, body: dict | None = None) -> dict:
        url = path if path.startswith("http") else f"{self.base}/{path}"
        if query:
            url += "?" + urllib.parse.urlencode(query)
        headers = {"Authorization": "Bearer " + apple_token(self.cfg["issuer_id"], self.cfg["key_id"], self.cfg["key_path"])}
        if body is not None:
            headers["Content-Type"] = "application/json"
        return http(method, url, headers, json.dumps(body).encode() if body is not None else None)

    def all(self, path: str, query: dict) -> list[dict]:
        items, url, q = [], path, query
        while url:
            page = self.call("GET", url, q)
            items += page.get("data", [])
            url, q = page.get("links", {}).get("next"), None
        return items

    @staticmethod
    def point(item: dict, territory: str | None = None) -> dict | None:
        try:
            place = territory or item["relationships"]["territory"]["data"]["id"]
            return {"id": item["id"], "territory": place, "price": Decimal(item["attributes"]["customerPrice"])}
        except (KeyError, TypeError):
            return None

    def create(self, code: str, percent: int, expires: dt.date | None, max_redemptions: int | None, full: Decimal) -> str:
        apps = self.all("v1/apps", {"filter[bundleId]": self.cfg["bundle_id"]})
        if not apps:
            raise Problem(f"No app with bundle ID {self.cfg['bundle_id']} in this App Store Connect account.")
        app_id = apps[0]["id"]
        iaps = self.all(f"v1/apps/{app_id}/inAppPurchasesV2", {"filter[productId]": self.cfg["iap_product_id"]})
        if not iaps:
            raise Problem(f"No in-app purchase {self.cfg['iap_product_id']} on this app.")
        iap_id = iaps[0]["id"]
        us = [p for p in (self.point(i, "USA") for i in self.all(f"v2/inAppPurchases/{iap_id}/pricePoints",
                                                                  {"filter[territory]": "USA", "limit": "200"})) if p]
        chosen = pick_price_point(us, full, percent)
        if chosen is None:
            raise Problem("Apple offers no price point for this discount" + (" (no free point: create a Free offer in App Store Connect, then rerun)." if percent >= 100 else "."))
        others = [p for p in (self.point(i) for i in self.all(f"v1/inAppPurchasePricePoints/{chosen['id']}/equalizations",
                                                             {"include": "territory", "limit": "200"})) if p]
        prices = [chosen] + [p for p in others if p["territory"] != "USA"]
        offer = self.call("POST", "v1/inAppPurchaseOfferCodes",
                          body=apple_offer_body(f"{code.upper()} {percent}%", iap_id, prices))
        offer_id = offer["data"]["id"]
        limit = min(max_redemptions or APPLE_MAX_REDEMPTIONS, APPLE_MAX_REDEMPTIONS)
        self.call("POST", "v1/inAppPurchaseOfferCodeCustomCodes", body=apple_custom_code_body(offer_id, code, limit, expires))
        price = "free" if chosen["price"] == 0 else f"US${chosen['price']} (≈{actual_percent(chosen['price'], full)}% off)"
        link = f"https://apps.apple.com/redeem?ctx=offercodes&id={app_id}&code={code.upper()}"
        return f"App Store: {code.upper()} → {price}, {limit:,} redemptions, {'until ' + expires.isoformat() if expires else 'no end date'}. Link: {link}"


class Stripe:
    base = "https://api.stripe.com/v1"

    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.key = os.environ.get("STRIPE_SECRET_KEY") or self.keychain(cfg.get("keychain_service", ""))
        if not self.key:
            raise Problem("No Stripe key. The owner stores one with: security add-generic-password -a \"$USER\" -s "
                          f"{cfg.get('keychain_service', 'stripe-secret-key')} -w   (it prompts; never paste keys into chat).")

    @staticmethod
    def keychain(service: str) -> str | None:
        if not service:
            return None
        result = subprocess.run(["security", "find-generic-password", "-s", service, "-w"], capture_output=True, text=True)
        if result.returncode != 0:
            return None
        return result.stdout.strip() or None

    @property
    def mode(self) -> str:
        return "TEST mode" if "_test_" in self.key else "LIVE mode"

    def post(self, path: str, params: dict) -> dict:
        return http("POST", f"{self.base}/{path}", {"Authorization": f"Bearer {self.key}", "Stripe-Version": STRIPE_VERSION,
                                                   "Content-Type": "application/x-www-form-urlencoded"},
                    urllib.parse.urlencode(params).encode())

    def create(self, code: str, percent: int, expires: dt.date | None, max_redemptions: int | None) -> str:
        coupon = self.post("coupons", stripe_coupon_params(code, percent, self.cfg["product_id"]))
        self.post("promotion_codes", stripe_promotion_params(code, coupon["id"], expires, max_redemptions))
        limit = f"{max_redemptions:,} redemptions" if max_redemptions else "unlimited redemptions"
        return f"Stripe ({self.mode}): {code.upper()} → {percent}% off, {limit}, {'until ' + expires.isoformat() if expires else 'no end date'}."


# MARK: CLI

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("command", choices=["plan", "create"])
    parser.add_argument("--config", required=True)
    parser.add_argument("--code", required=True)
    parser.add_argument("--percent", type=int, required=True)
    when = parser.add_mutually_exclusive_group(required=True)
    when.add_argument("--expires", type=dt.date.fromisoformat, help="last valid day, YYYY-MM-DD (Pacific time)")
    when.add_argument("--no-expiry", action="store_true")
    count = parser.add_mutually_exclusive_group()
    count.add_argument("--max", type=int, dest="max_redemptions")
    count.add_argument("--unlimited", action="store_true")
    parser.add_argument("--only", choices=["apple", "stripe"])
    parser.add_argument("--apply", action="store_true", help="actually create the codes")
    args = parser.parse_args(argv)

    with open(os.path.expanduser(args.config)) as f:
        cfg = json.load(f)
    full = Decimal(str(cfg["full_price"]))
    stores = [s for s in ("apple", "stripe") if s in cfg and args.only in (None, s)]
    if not stores:
        print("launch.json configures neither 'apple' nor 'stripe' (or --only excluded both).")
        return 2

    issues = validate(args.code, args.percent, args.expires, args.max_redemptions)
    if issues:
        print("\n".join("✗ " + i for i in issues))
        return 2

    print(f"{cfg.get('app', 'App')}: code {args.code.upper()}, {args.percent}% off US${full} "
          f"(target US${target_price(full, args.percent):.2f}), "
          f"{'until ' + args.expires.isoformat() if args.expires else 'no end date'}, "
          f"{args.max_redemptions or 'unlimited'} redemptions → {', '.join(stores)}")
    for note in notes(args.percent, args.expires, args.max_redemptions):
        print("  · " + note)

    if args.command == "plan" or not args.apply:
        print("\nNothing created (plan only). Add `create ... --apply` to make the codes.")
        return 0

    failed = False
    for store in stores:
        try:
            if store == "apple":
                print(Apple(cfg["apple"]).create(args.code, args.percent, args.expires, args.max_redemptions, full))
            else:
                print(Stripe(cfg["stripe"]).create(args.code, args.percent, args.expires, args.max_redemptions))
        except Problem as problem:
            failed = True
            print(f"✗ {store}: {problem}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
