const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "manifest.json"), "utf8"));

assert.equal(manifest.manifest_version, 3);
assert.equal(manifest.version, "0.7.2");
assert.equal(manifest.name, "Bean for the Web");
assert.deepEqual(manifest.host_permissions, ["http://*/*", "https://*/*"], "all-site coverage is the product default");
assert.equal(manifest.optional_host_permissions, undefined, "site-by-site permission prompts are intentionally removed");
assert.equal(manifest.content_scripts, undefined, "the blocklist is enforced through dynamic registration");
assert.ok(manifest.permissions.includes("scripting"));
assert.ok(manifest.permissions.includes("nativeMessaging"));
assert.ok(!manifest.permissions.includes("tabs"), "all-site host access already exposes the active HTTP(S) tab URL");
assert.equal(manifest.action.default_popup, "popup.html");
assert.equal(manifest.action.default_icon["128"], "icon128.png", "the official Bean artwork is used in Chrome's toolbar");
assert.ok(manifest.web_accessible_resources.some((entry) =>
  entry.resources.includes("icon128.png")
    && entry.matches.includes("http://*/*")
    && entry.matches.includes("https://*/*")
), "the inline UI can load the official Bean artwork on supported pages");

console.log("Browser extension manifest tests passed");
