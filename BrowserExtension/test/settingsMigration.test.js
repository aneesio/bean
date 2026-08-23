const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const path = require("node:path");

const source = fs.readFileSync(path.join(__dirname, "..", "background.js"), "utf8");

function runMigration(initial, { failSet = false } = {}) {
  let installedListener = null;
  let update = null;
  let removed = [];
  let registered = null;
  const stored = { ...initial };
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
        get: (_keys, callback) => callback(stored),
        set: (value, callback) => {
          update = JSON.parse(JSON.stringify(value));
          if (failSet) {
            chrome.runtime.lastError = { message: "simulated migration write failure" };
            if (callback) callback();
            chrome.runtime.lastError = null;
            return;
          }
          Object.assign(stored, update);
          if (callback) callback();
        },
        remove: (keys, callback) => {
          removed = [...keys];
          keys.forEach((key) => delete stored[key]);
          if (callback) callback();
        }
      }
    },
    scripting: {
      unregisterContentScripts: (_filter, callback) => callback(),
      registerContentScripts: (scripts, callback) => {
        registered = JSON.parse(JSON.stringify(scripts));
        callback();
      }
    }
  };

  vm.runInNewContext(source, { chrome, Object, setTimeout: () => 1, clearTimeout: () => {} });
  assert.ok(installedListener, "background registered an install listener");
  installedListener();
  // Values created by the VM have a different object prototype; serialize them
  // back into this realm before using strict structural assertions.
  return {
    update,
    removed,
    registered,
    stored: JSON.parse(JSON.stringify(stored))
  };
}

let migration = runMigration({ enabled: true, useBridge: true, localFallback: true });
assert.deepEqual(
  migration.update,
  {
    blockedSites: [],
    localFallback: true,
    settingsSchemaVersion: 6
  },
  "old unversioned preferences migrate to all-site coverage"
);
assert.deepEqual(migration.removed, ["enabled", "useBridge"]);
assert.equal("useBridge" in migration.stored, false, "the legacy AI control is deleted, not reset");
assert.equal("enabled" in migration.stored, false, "the retired global extension control is deleted");
assert.equal("legacyAIOptOut" in migration.stored, false, "an explicit old AI opt-in does not create a migration block");

migration = runMigration({
  enabled: false,
  blockedSites: ["example.com"],
  useBridge: true,
  settingsSchemaVersion: 6
});
assert.equal(
  migration.update.legacyAIOptOut,
  true,
  "an old global opt-out remains fail-closed for paid browser AI"
);
assert.deepEqual(migration.removed, ["enabled", "useBridge"], "schema 6 cleans up stray legacy controls");
assert.deepEqual(migration.stored.blockedSites, ["example.com"]);
assert.equal(migration.stored.legacyAIOptOut, true);
assert.deepEqual(
  migration.registered[0].matches,
  ["http://*/*", "https://*/*"],
  "local checks stay registered on unblocked sites despite the retired global opt-out"
);

migration = runMigration({
  enabled: false,
  blockedSites: ["example.com"],
  useBridge: true,
  settingsSchemaVersion: 5
});
assert.deepEqual(
  migration.update,
  {
    blockedSites: ["example.com"],
    localFallback: true,
    legacyAIOptOut: true,
    settingsSchemaVersion: 6
  },
  "schema 5 keeps its blocklist and preserves the old disabled state for paid AI"
);
assert.deepEqual(migration.removed, ["enabled", "useBridge"]);

migration = runMigration({
  enabled: false,
  allowedSites: ["mail.google.com"],
  useBridge: false,
  settingsSchemaVersion: 3
});
assert.deepEqual(
  migration.update,
  {
    blockedSites: [],
    localFallback: true,
    legacyAIOptOut: true,
    settingsSchemaVersion: 6
  },
  "the old allowlist becomes local all-site coverage while an explicit AI opt-out stays private"
);
assert.deepEqual(migration.removed, ["enabled", "useBridge"]);

migration = runMigration({
  blockedSites: ["private.example"],
  useBridge: false,
  settingsSchemaVersion: 6
});
assert.deepEqual(
  migration.update,
  { legacyAIOptOut: true },
  "a stray schema-6 AI opt-out is captured before the obsolete key is removed"
);
assert.deepEqual(migration.removed, ["useBridge"]);
assert.deepEqual(migration.stored.blockedSites, ["private.example"]);

migration = runMigration({});
assert.deepEqual(
  migration.update,
  {
    blockedSites: [],
    localFallback: true,
    settingsSchemaVersion: 6
  },
  "a fresh installation starts with all-site local checks available"
);
assert.deepEqual(migration.removed, []);
assert.equal("useBridge" in migration.stored, false);
assert.equal("legacyAIOptOut" in migration.stored, false, "fresh installs enable browser AI when the app is ready");

migration = runMigration({
  enabled: false,
  useBridge: false,
  blockedSites: ["private.example"],
  settingsSchemaVersion: 5
}, { failSet: true });
assert.deepEqual(migration.removed, [],
  "a failed migration write never removes the legacy privacy controls");
assert.equal(migration.stored.enabled, false);
assert.equal(migration.stored.useBridge, false);
assert.equal(migration.stored.settingsSchemaVersion, 5);
assert.equal("legacyAIOptOut" in migration.stored, false,
  "the failed marker write is not mistaken for a completed migration");

console.log("Browser extension settings migration tests passed");
