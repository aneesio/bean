const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

function load(relativePath) {
  const source = fs.readFileSync(path.join(__dirname, "..", relativePath), "utf8");
  const context = {
    window: { scrollX: 0, scrollY: 0 },
    document: {},
    NodeFilter: { SHOW_TEXT: 4 }
  };
  vm.runInNewContext(source, context);
  return context.window;
}

const detector = load("src/localDetector.js").BeanDetector;
const detectorIssues = detector.detect("i  recieve teh teh note");
assert.ok(detectorIssues.some((issue) => issue.original.includes("  ") && issue.type === "spacing"));
assert.ok(detectorIssues.some((issue) => issue.original === "recieve" && issue.suggestion === "receive"));
assert.ok(detectorIssues.some((issue) => issue.original === "teh teh" && issue.type === "grammar"));
assert.ok(detectorIssues.length <= 8);

const mapping = load("src/issueMapping.js").BeanMapping;
assert.deepEqual(
  JSON.parse(JSON.stringify(mapping.uniqueOffset("hello world", "world"))),
  { start: 6, end: 11 }
);
assert.equal(mapping.uniqueOffset("word word", "word"), null, "ambiguous text must not map");
assert.equal(mapping.replaceRangePreservingBoundaries("one\ntwo", 4, 7, "three"), "one\nthree");
assert.equal(mapping.replaceRangePreservingBoundaries("short", -1, 2, "x"), null);

const sanitized = mapping.sanitizeProofreadParagraphOutput("```\n\u200BFixed.\n```");
assert.equal(sanitized.text, "Fixed.");
assert.equal(sanitized.zeroWidthStripped, 1);

console.log("Browser extension detector and mapping tests passed");
