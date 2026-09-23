const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const test = require("node:test");
const source = fs.readFileSync("app/static/ugos-bootstrap.js", "utf8");
const pem = "-----BEGIN PUBLIC KEY-----\ntest\n-----END PUBLIC KEY-----";

function run(data, initial = {}) {
  const storage = new Map(Object.entries(initial));
  const status = {};
  let removed = false, redirect;
  const context = {
    window: {},
    document: { getElementById: id => id === "ugos-login-data" ? { textContent: JSON.stringify(data), remove() { removed = true; } } : status },
    localStorage: { getItem: k => storage.get(k) ?? null, setItem: (k, v) => storage.set(k, String(v)) },
    atob: x => Buffer.from(x, "base64").toString(),
    location: { hostname: "ugos.infocuspaly.com", port: "", replace(x) { redirect = x; } },
  };
  context.window.top = context.window;
  vm.runInNewContext(source, context);
  return { storage, status, removed, redirect };
}

test("native session replaces previous user's credentials and reloads desktop", () => {
  const d = { uid: 1001, username: "student", token: "new-token", public_key: Buffer.from(pem).toString("base64"), role: 2 };
  const result = run(d, { "user-id": "1002", proConfig: JSON.stringify({ accessInfo: { api_token: "old-token", third_token: "old-third" }, temporaryCode: "old-password" }) });
  assert.equal(result.redirect, "/desktop/?os=ugospro#/");
  assert.equal(result.storage.get("enPublicKey"), pem);
  assert.equal(JSON.parse(result.storage.get("proUserInfo")).uid, 1001);
  const config = JSON.parse(result.storage.get("proConfig"));
  assert.equal(config.accessInfo.api_token, "new-token");
  assert.equal(config.accessInfo.third_token, undefined);
  assert.equal(config.temporaryCode, null);
  assert.equal(result.storage.get("user-change"), "true");
  assert.equal(result.removed, true);
});

test("invalid or incomplete login never changes browser credentials", () => {
  const result = run({ uid: 1001, username: "student", token: "x", public_key: "bad" });
  assert.equal(result.redirect, undefined);
  assert.equal(result.storage.size, 0);
  assert.match(result.status.textContent, /Could not open UGOS/);
});

test("damaged preexisting config does not prevent login", () => {
  const result = run({ uid: 1001, username: "student", token: "x", public_key: Buffer.from(pem).toString("base64") }, { proConfig: "invalid JSON" });
  assert.equal(result.redirect, "/desktop/?os=ugospro#/");
});

test("native version fallback replaces stale metadata", () => {
  const result = run({ uid: 1001, username: "student", token: "x", public_key: Buffer.from(pem).toString("base64"), system_version: "1.14.1.0107" }, { proConfig: '{"system_version":99}' });
  assert.equal(JSON.parse(result.storage.get("proConfig")).system_version, 114010107);
});
