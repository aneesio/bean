const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "manifest.json"), "utf8"));

assert.equal(manifest.manifest_version, 3);
assert.equal(manifest.name.includes("Beta"), true);
assert.equal(manifest.host_permissions, undefined, "blanket required host permissions are forbidden");
assert.equal(manifest.content_scripts, undefined, "scripts must be registered only for approved sites");
assert.deepEqual(manifest.optional_host_permissions, ["http://*/*", "https://*/*"]);
assert.ok(manifest.permissions.includes("scripting"));
assert.ok(manifest.permissions.includes("nativeMessaging"));
assert.ok(!manifest.permissions.includes("tabs"), "tabs permission is unnecessary");

console.log("Browser extension manifest tests passed");
