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

  // Keep exact local occurrences; provider candidates may never supply local
  // offset hints. Local findings win over a provider targeting the same text.
  function mergeIssues(localIssues, providerIssues, maxIssues) {
    const limit = Number.isFinite(maxIssues) ? Math.max(0, Math.floor(maxIssues)) : 16;
    if (!limit) return [];
    const merged = [], localKeys = new Set(), seen = new Set();
    for (const issue of Array.isArray(localIssues) ? localIssues : []) {
      if (!issue || !isMeaningfulEdit(issue.original, issue.suggestion)) continue;
      const original = comparableText(issue.original);
      const key = Number.isInteger(issue.start) && Number.isInteger(issue.end)
        ? `${original}:${issue.start}:${issue.end}` : original;
      if (!original || seen.has(key)) continue;
      seen.add(key); localKeys.add(original); merged.push(issue);
      if (merged.length >= limit) return merged;
    }
    for (const issue of Array.isArray(providerIssues) ? providerIssues : []) {
      if (!issue || !isMeaningfulEdit(issue.original, issue.suggestion)) continue;
      const original = comparableText(issue.original);
      if (!original || localKeys.has(original) || seen.has(original)) continue;
      seen.add(original);
      merged.push({ original:issue.original, suggestion:issue.suggestion,
                    type:issue.type, explanation:issue.explanation, source:"ai" });
      if (merged.length >= limit) return merged;
    }
    return merged;
  }

  // The Mac checker returns offsets into the exact string it received. Never
  // guess an occurrence from its spelling: repeated words must remain distinct.
  function mergeLocalIssues(text, deterministicIssues, nativeIssues, maxIssues) {
    if (typeof text !== "string") return [];
    const limit = Number.isInteger(maxIssues) ? Math.max(0, maxIssues) : 64;
    const merged = [];
    for (const issue of [...(deterministicIssues || []), ...(nativeIssues || [])]) {
      if (!issue || !isMeaningfulEdit(issue.original, issue.suggestion)) continue;
      const start = Number.isInteger(issue.start) ? issue.start : issue.location;
      const end = Number.isInteger(issue.end) ? issue.end : start + issue.length;
      if (!Number.isInteger(start) || !Number.isInteger(end) || start < 0 ||
          end <= start || end > text.length || text.slice(start, end) !== issue.original ||
          issue.original.length > 200 || issue.suggestion.length > 200 ||
          /[\r\n\u2028\u2029\u0000-\u0008\u000B\u000C\u000E-\u001F]/.test(issue.suggestion)) continue;
      if (merged.some((other) => start < other.end && end > other.start)) continue;
      const alternatives = Array.isArray(issue.alternatives) ? [...new Set(issue.alternatives)].filter((value) =>
        typeof value === "string" && value.trim() && value !== issue.original && value !== issue.suggestion &&
        value.length <= 200 && !/[\r\n\u2028\u2029\u0000-\u001F]/.test(value)).slice(0,4) : [];
      merged.push({ ...issue, alternatives, start, end, source:"local",
        type:issue.type || issue.category || "spelling",
        explanation:issue.explanation || issue.message || "Spelling suggestion" });
    }
    return merged.sort((a, b) => a.start - b.start || a.end - b.end).slice(0, limit);
  }

  function localCheckChunks(text, maxChars = 6000) {
    if (typeof text !== "string") return [];
    const limit = Math.max(200, Math.min(8000, Math.floor(maxChars)));
    const chunks = [];
    let start = 0;
    while (start < text.length) {
      let end = Math.min(text.length, start + limit);
      if (end < text.length) {
        const slice = text.slice(start, end);
        const boundary = Math.max(slice.lastIndexOf("\n"), slice.lastIndexOf(" "), slice.lastIndexOf("\t"));
        if (boundary > limit / 2) end = start + boundary + 1;
        // Do not divide a UTF-16 surrogate pair.
        else if (/[\uD800-\uDBFF]/.test(text[end - 1])) end--;
      }
      chunks.push({ text:text.slice(start, end), start, end });
      start = end;
    }
    return chunks;
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

  function localBridgeReadiness(status, requiredProtocolVersion = BRIDGE_PROTOCOL_VERSION) {
    if (!status || status.ok !== true || status.bridgeAvailable !== true) {
      return { ready:false, code:"localBridgeUnavailable" };
    }
    if (status.compatible === false || status.protocolVersion !== requiredProtocolVersion) {
      return { ready:false, code:"localBridgeIncompatible" };
    }
    if (status.localCheckAvailable !== true) return { ready:false, code:"localCheckerUnavailable" };
    return { ready:true, code:"localCheckerReady" };
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
    mergeLocalIssues,
    localCheckChunks,
    boundedChangedBlock,
    bridgeReadiness,
    localBridgeReadiness,
    isPlainTextContentEditableBlock
  };
})();
