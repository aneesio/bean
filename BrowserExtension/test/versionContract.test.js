const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const root = path.join(__dirname, "..", "..");
const manifest = JSON.parse(fs.readFileSync(path.join(root, "BrowserExtension", "manifest.json"), "utf8"));
const plist = fs.readFileSync(path.join(root, "Resources", "Info.plist"), "utf8");
const appInfo = fs.readFileSync(path.join(root, "Sources", "Bean", "Core", "AppInfo.swift"), "utf8");
const background = fs.readFileSync(path.join(root, "BrowserExtension", "background.js"), "utf8");
const nativeHost = fs.readFileSync(path.join(root, "Sources", "Bean", "Core", "NativeMessagingHost.swift"), "utf8");

function requiredMatch(source, expression, description) {
  const match = source.match(expression);
  assert.ok(match, `could not read ${description}`);
  return match[1];
}

function versionAtLeast(candidate, minimum) {
  const parse = (value) => {
    assert.match(value, /^\d+(\.\d+){0,3}$/, `invalid numeric version: ${value}`);
    return value.split(".").map(Number);
  };
  const left = parse(candidate);
  const right = parse(minimum);
  const count = Math.max(left.length, right.length);
  for (let index = 0; index < count; index += 1) {
    const difference = (left[index] || 0) - (right[index] || 0);
    if (difference !== 0) return difference > 0;
  }
  return true;
}

function plistString(key) {
  return requiredMatch(
    plist,
    new RegExp(`<key>${key}</key>\\s*<string>([^<]+)</string>`),
    `${key} in Info.plist`
  );
}

const appVersion = plistString("CFBundleShortVersionString");
const appBuild = plistString("CFBundleVersion");
const appFallback = requiredMatch(appInfo, /static var version:[^\n]+\?\? "([^"]+)"/, "AppInfo version fallback");
const buildFallback = requiredMatch(appInfo, /static var build:[^\n]+\?\? "([^"]+)"/, "AppInfo build fallback");
const minimumAppVersion = requiredMatch(background, /const MINIMUM_APP_VERSION = "([^"]+)"/, "extension minimum app version");
const extensionProtocol = Number(requiredMatch(background, /const BRIDGE_PROTOCOL_VERSION = (\d+)/, "extension protocol version"));
const minimumExtensionVersion = requiredMatch(nativeHost, /static let minimumExtensionVersion = "([^"]+)"/, "app minimum extension version");
const appProtocol = Number(requiredMatch(nativeHost, /static let protocolVersion = (\d+)/, "app protocol version"));

assert.equal(appVersion, "1.6.0", "the in-development app release is 1.6.0");
assert.equal(appBuild, "11", "the in-development app build is 11");
assert.equal(manifest.version, "0.7.2", "the in-development extension release is 0.7.2");
assert.equal(appFallback, appVersion, "the unbundled app fallback must match Info.plist");
assert.equal(buildFallback, appBuild, "the unbundled build fallback must match Info.plist");
assert.equal(extensionProtocol, appProtocol, "the app and extension must speak the same bridge protocol");
assert.ok(versionAtLeast(appVersion, minimumAppVersion),
  `Bean ${appVersion} does not satisfy the extension minimum ${minimumAppVersion}`);
assert.ok(versionAtLeast(appFallback, minimumAppVersion),
  `the AppInfo fallback ${appFallback} does not satisfy the extension minimum ${minimumAppVersion}`);
assert.ok(versionAtLeast(manifest.version, minimumExtensionVersion),
  `extension ${manifest.version} does not satisfy the app minimum ${minimumExtensionVersion}`);

console.log("Bean app/extension version contract tests passed");
