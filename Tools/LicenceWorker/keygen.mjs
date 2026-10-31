// node keygen.mjs <slug> — makes the Ed25519 licence signing key for one app.
// Private half → ~/.<slug>/licence-signing-key.json (chmod 600, never in a repo, an app or a chat).
// Prints only the PUBLIC key, which goes into the app's StoreConfig.
import { generateKeyPairSync } from "node:crypto";
import { mkdirSync, writeFileSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const slug = process.argv[2];
if (!slug || !/^[a-z0-9-]+$/.test(slug)) { console.error("usage: node keygen.mjs <slug>"); process.exit(1); }
const dir = join(homedir(), `.${slug}`);
const file = join(dir, "licence-signing-key.json");
if (existsSync(file)) { console.error(`${file} already exists; keys already issued would stop working if it changed. Not overwriting.`); process.exit(1); }
const { privateKey, publicKey } = generateKeyPairSync("ed25519");
const record = {
  note: `Licence signing key for ${slug}. Keep private. LICENCE_PRIVATE_KEY secret = privateKeyPKCS8.`,
  created: new Date().toISOString(),
  privateKeyPKCS8: privateKey.export({ type: "pkcs8", format: "der" }).toString("base64"),
  publicKeyRaw: publicKey.export({ type: "spki", format: "der" }).subarray(12).toString("base64"),
};
mkdirSync(dir, { recursive: true, mode: 0o700 });
writeFileSync(file, JSON.stringify(record, null, 2) + "\n", { mode: 0o600 });
console.log(`Saved ${file}`);
console.log(`Public key for the app: ${record.publicKeyRaw}`);
