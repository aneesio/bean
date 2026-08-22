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
    scripting: {
      unregisterContentScripts: (_filter, callback) => callback(),
      registerContentScripts: (_scripts, callback) => callback()
    }
  };

  vm.runInNewContext(source, { chrome, Object, setTimeout: () => 1, clearTimeout: () => {} });
  assert.ok(installedListener, "background registered an install listener");
  installedListener();
  // Values created by the VM have a different object prototype; serialize them
  // back into this realm before using strict structural assertions.
  return update === null ? null : JSON.parse(JSON.stringify(update));
}

assert.deepEqual(
  runMigration({ enabled: true, useBridge: true, localFallback: true }),
  {
    enabled: true,
    blockedSites: [],
    useBridge: false,
    localFallback: true,
    settingsSchemaVersion: 4
  },
  "old unversioned preferences migrate to all-site local checks without enabling paid checks"
);

assert.equal(
  runMigration({ enabled: false, blockedSites: ["example.com"], useBridge: true, settingsSchemaVersion: 4 }),
  null,
  "deliberate version-four preferences are preserved"
);

assert.deepEqual(
  runMigration({ enabled: false, allowedSites: ["mail.google.com"], useBridge: true, settingsSchemaVersion: 3 }),
  {
    enabled: true,
    blockedSites: [],
    useBridge: true,
    localFallback: true,
    settingsSchemaVersion: 4
  },
  "the old allowlist becomes all-site coverage while an explicit AI choice is preserved"
);

assert.deepEqual(
  runMigration({}),
  {
    enabled: true,
    blockedSites: [],
    localFallback: true,
    useBridge: false,
    settingsSchemaVersion: 4
  },
  "a fresh installation starts with all-site local checks available"
);

console.log("Browser extension settings migration tests passed");
