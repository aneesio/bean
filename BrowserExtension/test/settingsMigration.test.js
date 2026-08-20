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
      onMessage: { addListener: () => {} },
      openOptionsPage: () => {},
      sendNativeMessage: () => {}
    },
    storage: {
      local: {
        get: (_keys, callback) => callback(initial),
        set: (value) => { update = value; }
      }
    },
    action: { onClicked: { addListener: () => {} } }
  };

  vm.runInNewContext(source, { chrome, Object });
  assert.ok(installedListener, "background registered an install listener");
  installedListener();
  // Values created by the VM have a different object prototype; serialize them
  // back into this realm before using strict structural assertions.
  return update === null ? null : JSON.parse(JSON.stringify(update));
}

assert.deepEqual(
  runMigration({ enabled: true, useBridge: true }),
  { useBridge: false, settingsSchemaVersion: 2 },
  "an old paid bridge preference is disabled exactly once"
);

assert.equal(
  runMigration({ enabled: true, useBridge: true, settingsSchemaVersion: 2 }),
  null,
  "a deliberate opt-in made after migration is preserved"
);

assert.deepEqual(
  runMigration({}),
  {
    enabled: false,
    allowlist: [],
    blocklist: [],
    localFallback: true,
    useBridge: false,
    settingsSchemaVersion: 2
  },
  "a fresh installation starts with only local checks available"
);

console.log("Browser extension settings migration tests passed");
