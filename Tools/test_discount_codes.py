"""python3 -m unittest test_discount_codes  (run from scripts/). No network."""
import datetime as dt
import json
import os
import subprocess
import tempfile
import unittest
from decimal import Decimal

import discount_codes as dc

TODAY = dt.date(2026, 10, 28)
POINTS = [{"id": f"p{v}", "territory": "USA", "price": Decimal(v)} for v in ("0", "0.49", "0.99", "1.49", "1.99", "2.49", "2.99")]


class Validation(unittest.TestCase):
    def test_accepts_the_supported_range(self):
        self.assertEqual(dc.validate("LAUNCH50", 10, None, None, TODAY), [])
        self.assertEqual(dc.validate("free100", 100, dt.date(2026, 12, 31), 500, TODAY), [])

    def test_rejects_out_of_range_and_bad_codes(self):
        self.assertTrue(dc.validate("LAUNCH50", 5, None, None, TODAY))
        self.assertTrue(dc.validate("LAUNCH50", 101, None, None, TODAY))
        self.assertTrue(dc.validate("LAUNCH-50", 50, None, None, TODAY))
        self.assertTrue(dc.validate("", 50, None, None, TODAY))
        self.assertTrue(dc.validate("X" * 65, 50, None, None, TODAY))
        self.assertTrue(dc.validate("OK", 50, TODAY, None, TODAY))
        self.assertTrue(dc.validate("OK", 50, None, 0, TODAY))

    def test_unlimited_is_capped_on_apple_and_said_so(self):
        text = " ".join(dc.notes(50, None, None, TODAY))
        self.assertIn("25,000", text)
        self.assertNotIn("25,000", " ".join(dc.notes(50, None, 100, TODAY)))


class ApplePricing(unittest.TestCase):
    def test_nearest_point_below_full_price(self):
        self.assertEqual(dc.pick_price_point(POINTS, Decimal("2.99"), 50)["price"], Decimal("1.49"))
        self.assertEqual(dc.pick_price_point(POINTS, Decimal("2.99"), 10)["price"], Decimal("2.49"))
        self.assertEqual(dc.pick_price_point(POINTS, Decimal("2.99"), 90)["price"], Decimal("0.49"))

    def test_hundred_percent_needs_a_free_point(self):
        self.assertEqual(dc.pick_price_point(POINTS, Decimal("2.99"), 100)["id"], "p0")
        self.assertIsNone(dc.pick_price_point(POINTS[1:], Decimal("2.99"), 100))

    def test_actual_percent(self):
        self.assertEqual(dc.actual_percent(Decimal("1.49"), Decimal("2.99")), 50)

    def test_request_bodies(self):
        prices = [POINTS[3], {"id": "q1", "territory": "CAN", "price": Decimal("1.99")}]
        body = dc.apple_offer_body("LAUNCH50 50%", "iap1", prices)
        self.assertEqual(len(body["included"]), 2)
        self.assertEqual(body["data"]["relationships"]["prices"]["data"][1]["id"], "${price-CAN}")
        code = dc.apple_custom_code_body("off1", "launch50", 25000, None)
        self.assertEqual(code["data"]["attributes"], {"customCode": "LAUNCH50", "numberOfCodes": 25000})
        self.assertEqual(dc.apple_custom_code_body("off1", "x", 5, dt.date(2026, 12, 31))["data"]["attributes"]["expirationDate"], "2026-12-31")


class StripeParams(unittest.TestCase):
    def test_limited_and_unlimited(self):
        coupon = dc.stripe_coupon_params("launch50", 50, "prod_X")
        self.assertEqual(coupon["percent_off"], "50")
        self.assertEqual(coupon["applies_to[products][0]"], "prod_X")
        self.assertEqual(dc.stripe_promotion_params("launch50", "c1", None, None), {"code": "LAUNCH50", "coupon": "c1"})
        limited = dc.stripe_promotion_params("a", "c1", dt.date(2026, 12, 31), 10)
        self.assertEqual(limited["max_redemptions"], "10")
        # 23:59:59 Pacific on 31 Dec 2026 (PST, UTC-8) = 07:59:59 UTC on 1 Jan 2027
        self.assertEqual(int(limited["expires_at"]), int(dt.datetime(2027, 1, 1, 7, 59, 59, tzinfo=dt.timezone.utc).timestamp()))


class AppleJWT(unittest.TestCase):
    def test_es256_token_verifies_with_openssl(self):
        with tempfile.TemporaryDirectory() as tmp:
            key = os.path.join(tmp, "AuthKey_TEST.p8")
            pub = os.path.join(tmp, "pub.pem")
            subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", key], check=True, capture_output=True)
            subprocess.run(["openssl", "pkey", "-in", key, "-pubout", "-out", pub], check=True, capture_output=True)
            token = dc.apple_token("issuer-uuid", "KEYID12345", key, now=1_800_000_000)
            head, body, sig = token.split(".")
            pad = lambda s: s + "=" * (-len(s) % 4)
            import base64
            self.assertEqual(json.loads(base64.urlsafe_b64decode(pad(head))), {"alg": "ES256", "kid": "KEYID12345", "typ": "JWT"})
            claims = json.loads(base64.urlsafe_b64decode(pad(body)))
            self.assertEqual(claims["exp"] - claims["iat"], 1200)
            raw = base64.urlsafe_b64decode(pad(sig))
            self.assertEqual(len(raw), 64)
            # Rebuild DER from raw r‖s and let openssl verify it.
            def integer(b):
                b = b.lstrip(b"\x00") or b"\x00"
                if b[0] & 0x80:
                    b = b"\x00" + b
                return bytes([2, len(b)]) + b
            seq = integer(raw[:32]) + integer(raw[32:])
            der = bytes([0x30, len(seq)]) + seq
            msg, sigf = os.path.join(tmp, "m"), os.path.join(tmp, "s")
            open(msg, "wb").write(f"{head}.{body}".encode())
            open(sigf, "wb").write(der)
            ok = subprocess.run(["openssl", "dgst", "-sha256", "-verify", pub, "-signature", sigf, msg], capture_output=True, text=True)
            self.assertIn("Verified OK", ok.stdout)


class CLI(unittest.TestCase):
    def test_plan_touches_nothing_and_exits_zero(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump({"app": "Demo", "full_price": "2.99", "apple": {}, "stripe": {}}, f)
        try:
            self.assertEqual(dc.main(["plan", "--config", f.name, "--code", "LAUNCH50", "--percent", "50", "--no-expiry", "--unlimited"]), 0)
            self.assertEqual(dc.main(["create", "--config", f.name, "--code", "LAUNCH50", "--percent", "50", "--expires", "2099-01-01"]), 0)
            self.assertEqual(dc.main(["plan", "--config", f.name, "--code", "BAD-CODE", "--percent", "50", "--no-expiry"]), 2)
        finally:
            os.unlink(f.name)


if __name__ == "__main__":
    unittest.main()
