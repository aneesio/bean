const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const extension = path.join(__dirname, "..");
const popupCSS = fs.readFileSync(path.join(extension, "popup.html"), "utf8");
const optionsCSS = fs.readFileSync(path.join(extension, "options.html"), "utf8");
const overlaySource = fs.readFileSync(path.join(extension, "src", "overlay.js"), "utf8");

// Capture the real interpolated shadow stylesheet and standalone confirmation
// styles without opening an extension or changing a user's browser settings.
const elements = [];
function element(tagName) {
  const node = {
    tagName, dataset: {}, style: {}, children: [],
    append(...children) { this.children.push(...children); },
    appendChild(child) { this.children.push(child); return child; },
    addEventListener() {}, setAttribute() {}, remove() {},
    attachShadow() { return element("shadow"); }
  };
  elements.push(node);
  return node;
}
let darkAppearance = false;
const context = {
  window: { scrollX: 0, scrollY: 0, matchMedia: () => ({ matches: darkAppearance }) },
  document: { body: element("body"), createElement: element },
  setTimeout: () => 1, clearTimeout() {}
};
vm.runInNewContext(overlaySource, context);
context.window.BeanOverlay.setFieldDisabled(false);
const overlayCSS = elements.find((node) => node.tagName === "style").textContent;
const dotRule = overlayCSS.match(/\.assistant-dot\s*\{([^}]+)\}/)[1];
assert.match(dotRule,/box-sizing:\s*border-box/,"the painted dot includes its border within its stated size");
assert.match(dotRule,/width:\s*8px/);assert.match(dotRule,/height:\s*8px/);
assert.match(overlayCSS,/\.assistant\s*\{[^}]*width:\s*28px;\s*height:\s*28px/,
  "shrinking the paint retains the accessible pointer target");
assert.match(overlayCSS,/\.assistant-issue-mark\s*\{[^}]*width:\s*1\.2px;\s*height:\s*4\.4px/);
assert.match(overlayCSS,/\.assistant-issue-mark::before\s*\{[^}]*height:\s*2\.6px/);
assert.match(overlayCSS,/\.assistant-issue-mark::after\s*\{[^}]*height:\s*1\.2px/);

function themes(css, selector, prefix = "") {
  const rules = [...css.matchAll(new RegExp(`${selector}\\s*\\{([^}]+)\\}`, "g"))];
  assert.equal(rules.length, 2, `${selector} provides light and dark theme tokens`);
  assert.match(css, /prefers-color-scheme:\s*dark/);
  return rules.map((rule) => Object.fromEntries(
    [...rule[1].matchAll(/--([a-z-]+)\s*:\s*([^;}]+)/g)]
      .map((match) => [match[1].replace(prefix, ""), match[2].trim()])
  ));
}

function rgb(value, backdrop = [0, 0, 0]) {
  if (value.startsWith("#")) {
    let hex = value.slice(1);
    if (hex.length === 3) hex = [...hex].map((digit) => digit + digit).join("");
    assert.equal(hex.length, 6, `unsupported color ${value}`);
    return [0, 2, 4].map((offset) => parseInt(hex.slice(offset, offset + 2), 16));
  }
  const match = value.match(/^rgba?\(([^)]+)\)$/);
  assert.ok(match, `unsupported color ${value}`);
  const channels = match[1].split(",").map(Number);
  const alpha = channels[3] ?? 1;
  return channels.slice(0, 3).map((channel, index) => channel * alpha + backdrop[index] * (1 - alpha));
}

function luminance(channels) {
  const linear = channels.map((value) => {
    const channel = value / 255;
    return channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4;
  });
  return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722;
}

function contrast(foreground, background, minimum, description, backdrop) {
  const first = luminance(rgb(foreground));
  const second = luminance(rgb(background, backdrop));
  const ratio = (Math.max(first, second) + 0.05) / (Math.min(first, second) + 0.05);
  assert.ok(ratio >= minimum, `${description}: ${ratio.toFixed(2)}:1 is below ${minimum}:1`);
}

const surfaces = [
  ["popup", popupCSS, themes(popupCSS, ":root")],
  ["options", optionsCSS, themes(optionsCSS, ":root")],
  ["overlay", overlayCSS, themes(overlayCSS, ":host", "bean-")]
];
for (const [name, css, palettes] of surfaces) {
  assert.match(css, /color:\s*var\(--(?:bean-)?primary-ink\)/, `${name} buttons use their theme's foreground`);
  assert.doesNotMatch(css, /#(?:8a4c17|e0a15e|713b10|efb779|d8d1c9|292622|8a4f00|f1b35b|a12622|ff8a80|f7e8e5|472a28|bd514c|24120f|6e56a6|c9b6ff)\b/i,
    `${name} has no brown or violet colors, including warning states`);
  palettes.forEach((palette, index) => {
    const appearance = index ? "dark" : "light";
    // Test translucent overlay cards over the worst extreme page backdrop.
    const backdrop = index ? [255, 255, 255] : [0, 0, 0];
    for (const background of [palette.surface, palette.paper].filter(Boolean)) {
      for (const foreground of ["ink", "muted", "accent", "warning", "danger"].filter((token) => palette[token])) {
        contrast(palette[foreground], background, 4.5, `${name} ${appearance} ${foreground} text`, backdrop);
      }
      contrast(palette.accent, background, 3, `${name} ${appearance} focus ring`, backdrop);
    }
    contrast(palette["primary-ink"], palette.accent, 4.5, `${name} ${appearance} primary button`);
    contrast(palette["primary-ink"], palette["accent-strong"], 4.5, `${name} ${appearance} hovered primary button`);
    contrast(palette.ink, palette["accent-tint"], 4.5, `${name} ${appearance} selected scope`);
    if (palette.quiet) contrast(palette.muted, palette.quiet, 4.5, `${name} ${appearance} neutral status pill`);
    if (palette.success) contrast(palette.success, palette["accent-tint"], 4.5, `${name} ${appearance} active status pill`);
    if (palette["danger-tint"]) {
      assert.match(css, /\.pill\.blocked\s*\{[^}]*background:\s*var\(--danger-tint\)[^}]*color:\s*var\(--danger\)/,
        "the blocked pill uses the checked theme foreground and background");
      contrast(palette.danger, palette["danger-tint"], 4.5, `${name} ${appearance} blocked status pill`);
    }
    if (palette.issue) contrast(palette["issue-mark"], palette.issue, 4.5, `${name} ${appearance} issue exclamation`);
    if (palette.warning) assert.equal(palette.warning, palette.accent,
      `${name} ${appearance} warnings use the Bean green accent`);
    for (const token of ["accent", "accent-strong", "accent-tint", "primary-ink", "ink", "muted"]) {
      assert.equal(palette[token], surfaces[0][2][index][token], `${name} ${appearance} ${token} agrees with the popup`);
    }
    for (const token of ["warning", "danger"].filter((token) => palette[token])) {
      assert.equal(palette[token], surfaces[0][2][index][token], `${name} ${appearance} semantic ${token} agrees with the popup`);
    }
  });
}

for (const dark of [false, true]) {
  darkAppearance = dark;
  context.window.BeanOverlay.flash(null, "Correction applied");
  const css = elements.at(-1).style.cssText;
  const background = css.match(/(?:^|;)background:([^;]+)/)[1];
  const foreground = css.match(/(?:^|;)color:([^;]+)/)[1];
  const palette = surfaces[0][2][Number(dark)];
  assert.equal(background, palette.accent, "standalone confirmation uses the current appearance's green accent");
  assert.equal(foreground, palette["primary-ink"]);
  contrast(foreground, background, 4.5, `${dark ? "dark" : "light"} standalone confirmation`);
}

console.log("Browser extension light/dark palette and contrast tests passed");
