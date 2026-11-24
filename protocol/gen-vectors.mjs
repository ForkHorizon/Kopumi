// Regenerates vectors/*.json. Node ≥ 20, no deps: `node protocol/gen-vectors.mjs`
import { createHash, hkdfSync, createCipheriv } from "node:crypto";
import { writeFileSync, mkdirSync } from "node:fs";

const dir = new URL("./vectors/", import.meta.url);
mkdirSync(dir, { recursive: true });
const save = (name, v) => writeFileSync(new URL(name, dir), JSON.stringify(v, null, 2) + "\n");
const sha = (s) => createHash("sha256").update(s).digest("hex");

save("hash.json", [
  "hello",
  "",
  "line one\r\nline two\n",
  "emoji 👋🏽 and ü (precomposed)",
  "ü (decomposed, must NOT be normalized)",
].map((text) => ({ prefix: "text", text, hash: "text:" + sha(Buffer.from(text, "utf8")) })));

const accountKey = Buffer.from([...Array(32).keys()]);
const hkdf = (info) => Buffer.from(hkdfSync("sha256", accountKey, Buffer.alloc(0), info, 32));
const encKey = hkdf("kopumi-enc-v1");
const authToken = hkdf("kopumi-auth-v1").toString("hex");
const id = "01936c2e-7b1a-7c00-8000-000000000001";
const plaintext = JSON.stringify({
  v: 1, id, createdAt: 1700000000000, updatedAt: 1700000000500, lastUsedAt: 1700000000500,
  deviceId: "01936c2e-0000-7000-8000-00000000000a", kind: "url", sourceApp: "com.apple.Safari",
  text: "https://example.com/👋", title: null, meta: "{\"host\":\"example.com\"}",
  contentHash: "text:" + sha("https://example.com/👋"), pinned: false, derivedFrom: null, deleted: false,
});
const nonce = Buffer.from("000102030405060708090a0b", "hex");
const c = createCipheriv("aes-256-gcm", encKey, nonce);
c.setAAD(Buffer.from(id, "utf8"));
const sealed = Buffer.concat([nonce, c.update(plaintext, "utf8"), c.final(), c.getAuthTag()]);
save("crypto.json", {
  accountKeyHex: accountKey.toString("hex"),
  accountKeyB64url: accountKey.toString("base64url"),
  encKeyHex: encKey.toString("hex"),
  authToken,
  authTokenSha256: sha(authToken),
  record: { id, plaintext, sealed: sealed.toString("base64") },
  pairing: {
    link: `kopumi://pair?r=${encodeURIComponent("https://relay.example.com")}&a=1b4e28ba-2fa1-41d2-883f-0016d3cca427&k=${accountKey.toString("base64url")}`,
    relay: "https://relay.example.com",
    accountId: "1b4e28ba-2fa1-41d2-883f-0016d3cca427",
  },
});

// Cases every platform's classifier must agree on. Address/date/phone detection is platform
// specific (NSDataDetector vs. Android regexes), so it's left out on purpose.
save("classify.json", {
  kinds: [
    ["https://example.com/a?b=1", "url"],
    ["me@example.com", "email"],
    ["#ff8800", "color"],
    ["rgb(10, 20, 30)", "color"],
    ["{\"a\": [1, 2]}", "json"],
    ["[not json", "text"],
    ["func foo() {\n    return 1\n}", "code"],
    ["name\tage\nbob\t3", "table"],
    ["Hello there, how are you doing today?", "text"],
  ].map(([text, kind]) => ({ text, kind })),
  sensitive: [
    "sk-ant-api03-abcdefghijklmnopqrstuvwxyz", "AKIAIOSFODNN7EXAMPLE", "4111 1111 1111 1111",
    "ghp_" + "a".repeat(36), "-----BEGIN OPENSSH PRIVATE KEY-----",
  ],
  notSensitive: ["hello world", "4111 1111 1111 1112", "call me at 415 555 0132"],
});
console.log("vectors written");
