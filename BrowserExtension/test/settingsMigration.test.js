const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const path = require("node:path");

const source = fs.readFileSync(path.join(__dirname, "..", "background.js"), "utf8");

function runMigration(initial) {
  let installedListener = null;
  let update = null;
  const chrome = {
    runtime: {
      onInstalled: { addListener: (listener) => { installedListener = listener; } },
      onStartup: { addListener: () => {} },
      onMessage: { addListener: () => {} },
      openOptionsPage: () => {},
      sendNativeMessage: () => {},
      lastError: null
    },
    storage: {
      local: {
        get: (_keys, callback) => callback(initial),
        set: (value, callback) => { update = value; if (callback) callback(); }
      }
    },
    action: { onClicked: { addListener: () => {} } },
    permissions: { onRemoved: { addListener: () => {} } },
    scripting: {
      unregisterContentScripts: (_filter, callback) => callback(),
      registerContentScripts: (_scripts, callback) => callback()
    }
  };

  vm.runInNewContext(source, { chrome, Object });
  assert.ok(installedListener, "background registered an install listener");
  installedListener();
  // Values created by the VM have a different object prototype; serialize them
  // back into this realm before using strict structural assertions.
  return update === null ? null : JSON.parse(JSON.stringify(update));
}

assert.deepEqual(
  runMigration({ enabled: true, useBridge: true, localFallback: true }),
  {
    enabled: false,
    allowedSites: [],
    useBridge: false,
    localFallback: true,
    settingsSchemaVersion: 3
  },
  "an old blanket-site and paid bridge preference is disabled exactly once"
);

assert.equal(
  runMigration({ enabled: true, allowedSites: ["mail.google.com"], useBridge: true, settingsSchemaVersion: 3 }),
  null,
  "a deliberate opt-in made after migration is preserved"
);

assert.deepEqual(
  runMigration({}),
  {
    enabled: false,
    allowedSites: [],
    localFallback: true,
    useBridge: false,
    settingsSchemaVersion: 3
  },
  "a fresh installation starts with only local checks available"
);

console.log("Browser extension settings migration tests passed");
