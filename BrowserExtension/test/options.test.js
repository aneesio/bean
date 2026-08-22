const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const elements = new Map();
function element(id) {
  if (!elements.has(id)) {
    elements.set(id, {
      id,
      checked: false,
      value: "",
      textContent: "",
      className: "",
      addEventListener: () => {}
    });
  }
  return elements.get(id);
}

const chrome = {
  storage: { local: { get: (_keys, callback) => callback({}), set: (_value, callback) => callback && callback() } },
  runtime: {
    id: "abcdefghijklmnopabcdefghijklmnop",
    sendMessage: (_message, callback) => callback && callback({
      ok: true,
      providerConfigured: true,
      webInlineEnabled: true,
      appVersion: "test"
    }),
    lastError: null
  }
};

const context = {
  chrome,
  document: { getElementById: element },
  navigator: { clipboard: { writeText: () => Promise.resolve() } },
  URL,
  setTimeout: (callback, delay) => { if (delay === 150) callback(); return 1; },
  clearTimeout: () => {}
};
const source = fs.readFileSync(path.join(__dirname, "..", "options.js"), "utf8");
const html = fs.readFileSync(path.join(__dirname, "..", "options.html"), "utf8");
vm.runInNewContext(source, context);

assert.match(html, /Blocked websites/);
assert.match(html, /id="s-sites"/);
assert.match(html, /id="s-budget"/);
assert.match(html, /On by default across ordinary text fields/);
assert.doesNotMatch(html, /Terminal|install_native_messaging_host/);
assert.equal(element("extensionID").textContent, chrome.runtime.id);
assert.notEqual(element("s-bridge").textContent, "Checking…");

assert.equal(context.normalizeHost("MAIL.Google.com"), "mail.google.com");
assert.equal(context.normalizeHost("https://app.slack.com/client"), "app.slack.com");
assert.equal(context.normalizeHost("ftp://example.com"), null);
assert.equal(context.normalizeHost("*.example.com"), null, "wildcards are not valid blocked-site entries");
assert.deepEqual(
  JSON.parse(JSON.stringify(context.parseSites("app.slack.com\nmail.google.com app.slack.com"))),
  ["app.slack.com", "mail.google.com"]
);
console.log("Browser extension options tests passed");
