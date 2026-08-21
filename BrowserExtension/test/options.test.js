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
  permissions: {
    getAll: (callback) => callback({ origins: [] }),
    request: (_permissions, callback) => callback(true),
    remove: (_permissions, callback) => callback(true)
  },
  runtime: { sendMessage: (_message, callback) => callback && callback({ ok: true }), lastError: null }
};

const context = {
  chrome,
  document: { getElementById: element },
  navigator: { clipboard: { writeText: () => Promise.resolve() } },
  URL,
  setTimeout: () => {}
};
const source = fs.readFileSync(path.join(__dirname, "..", "options.js"), "utf8");
vm.runInNewContext(source, context);

assert.equal(context.normalizeHost("MAIL.Google.com"), "mail.google.com");
assert.equal(context.normalizeHost("https://app.slack.com/client"), "app.slack.com");
assert.equal(context.normalizeHost("ftp://example.com"), null);
assert.equal(context.normalizeHost("*.example.com"), null, "wildcards are not exact site grants");
assert.deepEqual(
  JSON.parse(JSON.stringify(context.parseSites("app.slack.com\nmail.google.com app.slack.com"))),
  ["app.slack.com", "mail.google.com"]
);
assert.deepEqual(
  JSON.parse(JSON.stringify(context.originsForSites(["mail.google.com"]))),
  ["http://mail.google.com/*", "https://mail.google.com/*"]
);

console.log("Browser extension options tests passed");
