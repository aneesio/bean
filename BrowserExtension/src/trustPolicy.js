// Pure trust-boundary helpers shared by Bean's browser content script and its
// tests. Keeping these decisions independent of the DOM makes the rules easy to
// verify: provider results augment local findings, text requests stay bounded to
// the edited block, and unchanged output is never presented as a correction.
(function () {
  const ZERO_WIDTH = /[\u200B-\u200D\uFEFF]/g;
  const BRIDGE_PROTOCOL_VERSION = 1;

  function comparableText(value) {
    if (typeof value !== "string") return "";
    const cleaned = value.replace(ZERO_WIDTH, "").replace(/\r\n?/g, "\n");
    return typeof cleaned.normalize === "function" ? cleaned.normalize("NFC") : cleaned;
  }

  function isMeaningfulEdit(original, suggestion) {
    if (typeof original !== "string" || typeof suggestion !== "string") return false;
    if (!original || !suggestion) return false;
    return comparableText(original) !== comparableText(suggestion);
  }

  // Local findings win when both sources target the same original text. That
  // prevents two overlapping Apply actions and keeps the deterministic fix when
  // a provider proposes a different edit for the exact same range.
  function mergeIssues(localIssues, providerIssues, maxIssues) {
    const limit = Number.isFinite(maxIssues) ? Math.max(0, Math.floor(maxIssues)) : 16;
    const merged = [];
    const seenOriginals = new Set();
    for (const source of [localIssues, providerIssues]) {
      if (!Array.isArray(source)) continue;
      for (const issue of source) {
        if (!issue || !isMeaningfulEdit(issue.original, issue.suggestion)) continue;
        const key = comparableText(issue.original);
        if (!key || seenOriginals.has(key)) continue;
        seenOriginals.add(key);
        merged.push(issue);
        if (merged.length >= limit) return merged;
      }
    }
    return merged;
  }

  function clamp(value, low, high) {
    return Math.max(low, Math.min(high, value));
  }

  // Returns only the line/block around the edit point. A very long single-line
  // editor is bounded around the caret without exceeding maxChars. Offsets are
  // retained so callers can verify the block still matches before sending it.
  function boundedChangedBlock(value, caretOffset, maxChars) {
    if (typeof value !== "string" || !value.length) return null;
    const limit = Number.isFinite(maxChars) ? Math.max(1, Math.floor(maxChars)) : 2000;
    const caret = clamp(Number.isFinite(caretOffset) ? Math.floor(caretOffset) : value.length, 0, value.length);
    // When Enter was the edit, the caret sits just after a newline. Use the line
    // that was completed instead of the new empty line.
    const anchor = caret > 0 && value[caret - 1] === "\n" ? caret - 1 : caret;
    let start = value.lastIndexOf("\n", Math.max(0, anchor - 1)) + 1;
    let end = value.indexOf("\n", anchor);
    if (end < 0) end = value.length;

    if (end - start > limit) {
      const half = Math.floor(limit / 2);
      let boundedStart = clamp(anchor - half, start, Math.max(start, end - limit));
      let boundedEnd = Math.min(end, boundedStart + limit);

      // Prefer whole-word edges when a nearby boundary is available, while
      // preserving the hard size cap. Exact offsets still make verification safe.
      if (boundedStart > start) {
        const boundary = value.slice(boundedStart, Math.min(end, boundedStart + 64)).search(/\s/);
        if (boundary >= 0) boundedStart += boundary + 1;
      }
      boundedEnd = Math.min(end, boundedStart + limit);
      if (boundedEnd < end) {
        const chunk = value.slice(boundedStart, boundedEnd);
        const boundary = Math.max(chunk.lastIndexOf(" "), chunk.lastIndexOf("\t"));
        if (boundary > Math.floor(limit * 0.6)) boundedEnd = boundedStart + boundary;
      }
      start = boundedStart;
      end = boundedEnd;
    }

    const text = value.slice(start, end);
    return text.trim() ? { text, start, end } : null;
  }

  // Fail-closed readiness gate for every text-bearing native request. Missing
  // fields are deliberately incompatible: older hosts may be connected but do
  // not implement Bean's current privacy/status handshake.
  function bridgeReadiness(status, requiredProtocolVersion) {
    const required = Number.isInteger(requiredProtocolVersion)
      ? requiredProtocolVersion
      : BRIDGE_PROTOCOL_VERSION;
    if (!status || status.ok !== true) return { ready: false, code: "bridgeStatusUnavailable" };
    if (status.bridgeAvailable !== true) return { ready: false, code: "bridgeDisconnected" };
    if (status.compatible === false || status.protocolVersion !== required) {
      return { ready: false, code: "bridgeProtocolIncompatible" };
    }
    if (status.providerConfigured !== true) return { ready: false, code: "bridgeProviderNotConfigured" };
    if (status.webInlineEnabled !== true) return { ready: false, code: "bridgeWebInlineDisabled" };
    if (status.automaticAccountingAvailable !== true) {
      return { ready: false, code: "bridgeAccountingUnavailable" };
    }
    if (status.browserAIConsentRequired === true || status.browserAIEnabled === false) {
      return { ready: false, code: "bridgeConsentRequired" };
    }
    return { ready: true, code: "bridgeReady" };
  }

  // Whole-block contenteditable replacement uses text-node offsets. A visual
  // <br> appears in innerText but not textContent, so even that otherwise simple
  // element makes the sent paragraph and replacement coordinate systems differ.
  // Keep paragraph Fix to literal text nodes; verified individual ranges remain
  // available in richer blocks.
  function isPlainTextContentEditableBlock(block) {
    if (!block || !block.childNodes) return false;
    return Array.from(block.childNodes).every((node) => node && node.nodeType === 3);
  }

  window.BeanTrustPolicy = {
    BRIDGE_PROTOCOL_VERSION,
    comparableText,
    isMeaningfulEdit,
    mergeIssues,
    boundedChangedBlock,
    bridgeReadiness,
    isPlainTextContentEditableBlock
  };
})();
