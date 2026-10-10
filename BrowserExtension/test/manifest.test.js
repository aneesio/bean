const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "manifest.json"), "utf8"));

assert.equal(manifest.manifest_version, 3);
assert.equal(manifest.version, "0.8.7");
assert.equal(manifest.name, "Bean for the Web");
assert.deepEqual(manifest.host_permissions, ["http://*/*", "https://*/*"], "all-site coverage is the product default");
assert.equal(manifest.optional_host_permissions, undefined, "site-by-site permission prompts are intentionally removed");
assert.equal(manifest.content_scripts, undefined, "the blocklist is enforced through dynamic registration");
assert.ok(manifest.permissions.includes("scripting"));
assert.ok(manifest.permissions.includes("nativeMessaging"));
assert.ok(!manifest.permissions.includes("tabs"), "all-site host access already exposes the active HTTP(S) tab URL");
assert.equal(manifest.action.default_popup, "popup.html");
const expectedIcons = Object.fromEntries([16, 32, 48, 128].map((size) => [String(size), `icon${size}.png`]));
assert.deepEqual(manifest.action.default_icon, expectedIcons, "Chrome's toolbar uses artwork at each declared size");
assert.deepEqual(manifest.icons, expectedIcons, "extension management uses artwork at each declared size");
for (const [size, name] of Object.entries(expectedIcons)) {
  const png = fs.readFileSync(path.join(__dirname, "..", name));
  assert.equal(png.subarray(0, 8).toString("hex"), "89504e470d0a1a0a", `${name} is a PNG`);
  assert.equal(png.subarray(12, 16).toString("ascii"), "IHDR");
  assert.equal(png.readUInt32BE(16), Number(size), `${name} width matches its declared toolbar size`);
  assert.equal(png.readUInt32BE(20), Number(size), `${name} height matches its declared toolbar size`);
}
assert.ok(manifest.web_accessible_resources.some((entry) =>
  entry.resources.includes("icon128.png")
    && entry.matches.includes("http://*/*")
    && entry.matches.includes("https://*/*")
), "the inline UI can load the official Bean artwork on supported pages");

console.log("Browser extension manifest tests passed");
