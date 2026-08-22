const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "..", "background.js"), "utf8");
let startupListener;
let registered = null;
const chrome = {
  runtime: {
    onInstalled: { addListener: () => {} },
    onStartup: { addListener: (listener) => { startupListener = listener; } },
    onMessage: { addListener: () => {} },
    openOptionsPage: () => {},
    sendNativeMessage: () => {},
    lastError: null
  },
  storage: { local: { get: (_keys, callback) => callback({
    enabled: true,
    blockedSites: ["example.com"]
  }) } },
  action: { onClicked: { addListener: () => {} } },
  scripting: {
    unregisterContentScripts: (_filter, callback) => callback(),
    registerContentScripts: (scripts, callback) => { registered = scripts[0]; callback(); }
  }
};

vm.runInNewContext(source, { chrome, Object, Set, setTimeout, clearTimeout });
startupListener();

assert.deepEqual(JSON.parse(JSON.stringify(registered.matches)), ["http://*/*", "https://*/*"]);
assert.ok(registered.excludeMatches.includes("https://example.com/*"));
assert.ok(registered.excludeMatches.includes("https://*.example.com/*"));
assert.deepEqual(JSON.parse(JSON.stringify(registered.js)), [
  "src/localDetector.js", "src/issueMapping.js", "src/overlay.js", "src/contentScript.js"
]);

const content = fs.readFileSync(path.join(__dirname, "..", "src", "contentScript.js"), "utf8");
const overlay = fs.readFileSync(path.join(__dirname, "..", "src", "overlay.js"), "utf8");
assert.match(content, /disabledFields: new WeakSet\(\)/);
assert.match(content, /function disableCurrentSite\(\)/);
assert.match(overlay, /Disable on this field/);
assert.match(overlay, /Disable on this website/);
assert.match(overlay, /mouseenter[\s\S]*onActivateGroup/);

console.log("Browser extension coverage and opt-out tests passed");
