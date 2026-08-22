const path = require("node:path");
const { spawnSync } = require("node:child_process");

const tests = ["settingsMigration.test.js", "background.test.js", "coverage.test.js", "core.test.js", "options.test.js", "manifest.test.js"];
for (const test of tests) {
  const result = spawnSync(process.execPath, [path.join(__dirname, test)], { stdio: "inherit" });
  if (result.status !== 0) process.exit(result.status || 1);
}

console.log("All browser extension tests passed");
