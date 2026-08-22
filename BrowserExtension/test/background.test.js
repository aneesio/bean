const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "..", "background.js"), "utf8");
let messageListener;
let nativeCallback;
let timeoutCallback;
let cleared = false;

const chrome = {
  runtime: {
    onInstalled: { addListener: () => {} },
    onStartup: { addListener: () => {} },
    onMessage: { addListener: (listener) => { messageListener = listener; } },
    openOptionsPage: () => {},
    sendNativeMessage: (_host, _message, callback) => { nativeCallback = callback; },
    lastError: null
  },
  storage: { local: { get: (_keys, callback) => callback({}) } },
  action: { onClicked: { addListener: () => {} } },
  scripting: {
    unregisterContentScripts: (_filter, callback) => callback(),
    registerContentScripts: (_scripts, callback) => callback()
  }
};

vm.runInNewContext(source, {
  chrome,
  Object,
  Set,
  setTimeout: (callback) => { timeoutCallback = callback; return 1; },
  clearTimeout: () => { cleared = true; }
});

assert.ok(messageListener, "background registered its request listener");
let responses = [];
assert.equal(messageListener({ type: "getStatus" }, {}, (value) => responses.push(value)), true);
assert.ok(nativeCallback, "native request was sent");
assert.ok(timeoutCallback, "native request received a deadline");

timeoutCallback();
assert.equal(responses.length, 1);
assert.equal(responses[0].errorCode, "bridgeTimeout");

nativeCallback({ ok: true });
assert.equal(responses.length, 1, "late native replies cannot answer the channel twice");
assert.equal(cleared, true);

console.log("Browser extension background timeout tests passed");
