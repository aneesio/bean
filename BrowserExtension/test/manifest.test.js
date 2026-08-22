const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "manifest.json"), "utf8"));

assert.equal(manifest.manifest_version, 3);
assert.equal(manifest.version, "0.5.0");
assert.equal(manifest.name.includes("Beta"), true);
assert.deepEqual(manifest.host_permissions, ["http://*/*", "https://*/*"], "all-site coverage is the product default");
assert.equal(manifest.optional_host_permissions, undefined, "site-by-site permission prompts are intentionally removed");
assert.equal(manifest.content_scripts, undefined, "the blocklist is enforced through dynamic registration");
assert.ok(manifest.permissions.includes("scripting"));
assert.ok(manifest.permissions.includes("nativeMessaging"));
assert.ok(!manifest.permissions.includes("tabs"), "tabs permission is unnecessary");

console.log("Browser extension manifest tests passed");
