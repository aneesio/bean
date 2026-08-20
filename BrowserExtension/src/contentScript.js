// Bean content script — orchestrates inline proofreading in web text fields.
//
// Off by default. Activates only when enabled for the current site (options).
// Supports textarea, text inputs, and contenteditable. Skips password/search
// fields, code editors, and Google Docs. Applying one fix continues to the next.
//
// PRIVACY: no text is logged, stored, or sent anywhere by this script. (An
// optional LLM provider would send only the focused field's text, and only when
// the user configures it — see README. The default local detector is offline.)
(function () {
  const DEBOUNCE_MS = 1200;
  const BRIDGE_MIN_INTERVAL_MS = 15000;
  const SETTINGS_SCHEMA_VERSION = 2;
  const state = { active: null, entries: [], selectedId: null, fingerprint: 0, shownFingerprint: 0,
                  ignored: new Set(), reqGen: 0, groups: [], selectedGroupId: null,
                  correctedFps: new Set(), fixingGroup: false,
                  enabled: false, allowlist: [], blocklist: [], useBridge: false, localFallback: true };
  let debounce = null, scrollThrottle = null;
  let lastBridgeAt = 0;

  // --- Settings -------------------------------------------------------------
  function host() { return location.host; }
  function siteAllowed() {
    if (!state.enabled) return false;
    if (state.blocklist.includes(host())) return false;
    return state.allowlist.length === 0 || state.allowlist.includes(host());
  }
  function loadSettings(cb) {
    chrome.storage.local.get(["enabled", "allowlist", "blocklist", "useBridge", "localFallback", "settingsSchemaVersion"], (s) => {
      state.enabled = !!s.enabled;
      state.allowlist = s.allowlist || [];
      state.blocklist = s.blocklist || [];
      // Requiring the current schema makes an old persisted `useBridge: true`
      // harmless even if this content script starts before migration completes.
      state.useBridge = s.settingsSchemaVersion >= SETTINGS_SCHEMA_VERSION && !!s.useBridge;
      state.localFallback = s.localFallback !== false; // default on
      cb && cb();
    });
  }

  function uuid() { return (Date.now().toString(36) + Math.random().toString(36).slice(2)); }

  // Reason codes only — never any text. Debug logging is off by default.
  const DEBUG = false;
  function reason(code) { if (DEBUG) console.debug("[bean]", code); }

  // Ask the Bean app (native bridge) for issue candidates. Resolves to
  // { issues: array|null, code }. `issues === null` means "use local fallback".
  // Sets a cooldown for missing-key / web-inline-disabled so we don't spam.
  let bridgeCooldownUntil = 0, bridgeCooldownCode = "bridgeFallbackLocal";
  function bridgeIssues(text, fieldType) {
    if (!state.useBridge) return Promise.resolve({ issues: null, code: "bridgeFallbackLocal" });
    const now = Date.now();
    if (now < bridgeCooldownUntil) return Promise.resolve({ issues: null, code: bridgeCooldownCode });
    if (now - lastBridgeAt < BRIDGE_MIN_INTERVAL_MS) return Promise.resolve({ issues: null, code: "bridgeRateLimited" });
    lastBridgeAt = now;
    return new Promise((resolve) => {
      let done = false;
      const finish = (v) => { if (!done) { done = true; reason(v.code); resolve(v); } };
      const timer = setTimeout(() => finish({ issues: null, code: "bridgeTimeout" }), 12000);
      try {
        chrome.runtime.sendMessage(
          { type: "detectIssues", request: {
              id: uuid(), type: "detectIssues",
              source: { surface: "browserExtension", urlHost: location.host, fieldType },
              settings: { maxIssues: 8 }, text } },
          (resp) => {
            clearTimeout(timer);
            if (!resp) { finish({ issues: null, code: "bridgeUnavailable" }); return; }
            if (resp.ok && Array.isArray(resp.issues)) {
              finish({ issues: resp.issues, code: resp.issues.length ? "bridgeProviderIssues" : "bridgeNoIssues" });
              return;
            }
            const code = resp.errorCode || "bridgeMalformedResponse";
            if (code === "missingApiKey") { bridgeCooldownUntil = now + 60000; bridgeCooldownCode = "bridgeMissingApiKey"; }
            else if (code === "webInlineDisabled") { bridgeCooldownUntil = now + 120000; bridgeCooldownCode = "bridgeWebInlineDisabled"; }
            else if (code === "bridgeUnavailable" || code === "notInstalled") { bridgeCooldownUntil = now + 30000; bridgeCooldownCode = "bridgeUnavailable"; }
            finish({ issues: null, code: "bridge_" + code });
          }
        );
      } catch (e) { clearTimeout(timer); finish({ issues: null, code: "bridgeUnavailable" }); }
    });
  }
  chrome.storage.onChanged.addListener(() => loadSettings(() => {
    bridgeCooldownUntil = 0; // settings changed → re-evaluate bridge
    if (!siteAllowed()) teardown();
  }));

  // --- Field helpers --------------------------------------------------------
  function isEditable(el) {
    if (!el || el.nodeType !== Node.ELEMENT_NODE) return false;
    if (el.isContentEditable) return true;
    if (el.tagName === "TEXTAREA") return true;
    if (el.tagName === "INPUT") {
      const t = (el.type || "text").toLowerCase();
      return t === "text"; // text only; email/url/search/etc. are excluded below
    }
    return false;
  }
  function isExcluded(el) {
    // Interactive controls nested in a contenteditable region inherit
    // `isContentEditable`; they still are not typing surfaces.
    if (el.closest("button, a[href], [role='button'], [role='link'], [role='checkbox'], [role='radio'], [role='switch'], [role='tab'], [role='menuitem'], [role='option']")) return true;
    if (el.closest("[inert], [aria-disabled='true'], [aria-readonly='true']")) return true;
    // Secure / non-prose / non-editable inputs.
    if (el.tagName === "INPUT") {
      const t = (el.type || "text").toLowerCase();
      if (["password", "search", "email", "url", "tel", "number"].includes(t)) return true;
    }
    if (el.disabled || el.readOnly) return true;
    if (el.getAttribute("contenteditable") === "false") return true;
    const editableRoot = el.closest("[contenteditable]");
    if (editableRoot && editableRoot.getAttribute("contenteditable") === "false") return true;
    // Hidden / zero-size.
    if (!el.offsetParent && el.tagName !== "BODY") return true;
    const rect = el.getBoundingClientRect();
    if (rect.width < 8 || rect.height < 8) return true;
    // Code editors and Google Docs canvas.
    if (el.closest(".CodeMirror, .monaco-editor, .ace_editor, [role='code'], pre, code")) return true;
    if (location.host === "docs.google.com" && location.pathname.startsWith("/document")) return true;
    return false;
  }
  function getText(el) {
    return el.isContentEditable ? el.innerText : el.value;
  }
  function fingerprint(s) {
    let h = 2166136261;
    for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = (h * 16777619) >>> 0; }
    return h;
  }

  // Nearest block-level ancestor of a contenteditable text node, bounded by the
  // editor root. Used to group issues by visual paragraph. Returns null if the
  // node sits directly in the root with no block wrapper (then it won't group).
  const BLOCK_TAGS = { P: 1, DIV: 1, LI: 1, BLOCKQUOTE: 1, H1: 1, H2: 1, H3: 1, H4: 1, H5: 1, H6: 1, TD: 1, SECTION: 1, ARTICLE: 1 };
  function blockAncestor(node, root) {
    let el = node && node.nodeType === 3 ? node.parentElement : node;
    while (el && el !== root) {
      if (BLOCK_TAGS[el.tagName]) return el;
      el = el.parentElement;
    }
    return null;
  }

  // --- Lifecycle ------------------------------------------------------------
  document.addEventListener("focusin", (e) => {
    if (!siteAllowed()) return;
    const el = e.target;
    if (!isEditable(el) || isExcluded(el)) { teardown(); return; }
    setActive(el);
  }, true);

  // Defensive: don't tear down if focus moved INTO Bean's overlay UI. (With the
  // card's mousedown-preventDefault the field shouldn't blur at all, but guard
  // anyway — relatedTarget for a shadow element is retargeted to the host.)
  document.addEventListener("focusout", (e) => {
    const rt = e.relatedTarget;
    if (rt && (rt.id === "bean-inline-host" || (rt.dataset && rt.dataset.bean === "overlay"))) return;
    teardown();
  }, true);

  // True when an event originates inside Bean's overlay (card or highlight),
  // using composedPath so Shadow DOM is handled correctly.
  function isBeanOverlayEvent(e) {
    const path = e.composedPath ? e.composedPath() : [];
    return path.some((n) => n && (n.id === "bean-inline-host" || (n.dataset && n.dataset.bean === "overlay")));
  }

  window.addEventListener("scroll", () => {
    if (!state.active || !state.entries.length) return;
    if (scrollThrottle) return;
    scrollThrottle = setTimeout(() => { scrollThrottle = null; recomputeRects(); }, 60);
  }, true);
  window.addEventListener("resize", () => { if (state.active) recomputeRects(); });

  function setActive(el) {
    if (state.active === el) return;
    teardown();
    state.active = el;
    el.addEventListener("input", onInput, true);
    document.addEventListener("mousedown", onDocMouseDown, true);
    document.addEventListener("keydown", onDocKeyDown, true);
    scheduleCheck();
  }
  function onInput() {
    // Typing hides the overlay; invalidate in-flight requests; re-check later.
    state.reqGen++;
    BeanOverlay.clear();
    state.entries = []; state.selectedId = null; state.shownFingerprint = 0;
    state.groups = []; state.selectedGroupId = null;
    scheduleCheck();
  }
  function scheduleCheck() {
    if (debounce) clearTimeout(debounce);
    debounce = setTimeout(check, DEBOUNCE_MS);
  }
  function clearOverlay() {
    state.entries = []; state.selectedId = null; state.shownFingerprint = 0;
    state.groups = []; state.selectedGroupId = null;
    BeanOverlay.clear();
  }
  function teardown() {
    if (debounce) { clearTimeout(debounce); debounce = null; }
    if (state.active) state.active.removeEventListener("input", onInput, true);
    document.removeEventListener("mousedown", onDocMouseDown, true);
    document.removeEventListener("keydown", onDocKeyDown, true);
    state.active = null;
    state.reqGen++;
    clearOverlay();
  }

  // Click in our overlay UI → ignore; click into the active field → close card,
  // keep highlights; click anywhere else → clear overlay.
  function onDocMouseDown(e) {
    if (!state.active) return;
    if (isBeanOverlayEvent(e)) { reason("insideBeanUIClickIgnored"); return; } // never dismiss on our own UI
    if (e.target === state.active || (state.active.contains && state.active.contains(e.target))) {
      if (state.selectedId || state.selectedGroupId) { state.selectedId = null; state.selectedGroupId = null; renderOverlay(); }
      return;
    }
    reason("clickAwayDismiss");
    clearOverlay();
  }
  function onDocKeyDown(e) {
    if (e.key === "Escape" && state.entries.length) {
      if (state.selectedId || state.selectedGroupId) { state.selectedId = null; state.selectedGroupId = null; renderOverlay(); }
      else clearOverlay();
    }
  }

  // --- Detect + map ---------------------------------------------------------
  function check() {
    const el = state.active;
    if (!el || !document.contains(el)) { teardown(); return; }
    const text = getText(el);
    if (!text || text.length < 4 || text.length > 5000) { clearOverlay(); return; }
    const fp = fingerprint(text);
    if (fp === state.shownFingerprint && state.entries.length) return; // already showing for this text
    const fieldType = el.isContentEditable ? "contenteditable" : (el.tagName || "").toLowerCase();
    const gen = ++state.reqGen;

    bridgeIssues(text, fieldType).then((result) => {
      // Stale (typing/refocus happened) → ignore. Field changed → ignore.
      if (gen !== state.reqGen || el !== state.active || getText(el) !== text) return;
      const candidates = result.issues !== null ? result.issues : (state.localFallback ? BeanDetector.detect(text) : []);
      state.fingerprint = fp;
      state.shownFingerprint = fp;
      state.entries = mapEntries(el, text, candidates);
      state.selectedId = null;
      renderOverlay();
    });
  }

  function isSafeCandidate(issue) {
    if (!issue || typeof issue.original !== "string" || typeof issue.suggestion !== "string") return false;
    if (!issue.original || !issue.suggestion || issue.original === issue.suggestion) return false;
    if (issue.original.length < 2 || issue.original.length > 200) return false; // localized only
    if (issue.suggestion.length > 200) return false;
    if (issue.suggestion === issue.original + issue.original) return false; // obvious duplication artifact
    // LINE-BREAK SAFETY: an issue range must never include a paragraph/line
    // break, so applying a fix can never merge paragraphs or drop a newline.
    if (/[\n\r]/.test(issue.original)) { reason("lineBreakRiskRefused"); return false; }
    return true;
  }
  function ignoreKey(original) { return original + "::" + state.fingerprint; }

  // Builds entries whose rects come from the SAME source used to apply:
  //   contenteditable → a unique DOM Range over the text nodes (rects + apply)
  //   textarea/input  → a verified value offset (rects via mirror + apply)
  function mapEntries(el, text, candidates) {
    const kind = el.isContentEditable ? "ce" : "ta";
    const entries = [];
    let i = 0;
    for (const issue of candidates) {
      if (!isSafeCandidate(issue)) continue;
      if (state.ignored.has(ignoreKey(issue.original))) continue;
      let entry = null;
      if (kind === "ce") {
        const range = BeanMapping.findUniqueRange(el, issue.original); // null if missing/ambiguous/mismatch
        if (!range) { reason("mapMissingSkipped"); continue; }
        const rects = BeanMapping.rectsFromRange(range);
        if (!rects.length) continue;
        // Paragraph = nearest block ancestor (p/div/li/blockquote/heading) inside
        // the editor; null if none (then this issue won't group).
        const block = blockAncestor(range.startContainer, el);
        const paraText = block ? block.innerText : null;
        entry = { id: "i" + i++, issue, kind, original: issue.original, rects, blockEl: block, paraText,
                  sortKey: rects[0].y * 100000 + rects[0].x };
      } else {
        const off = BeanMapping.uniqueOffset(text, issue.original);
        if (!off) { reason("mapMissingSkipped"); continue; }
        if (el.value.slice(off.start, off.end) !== issue.original) continue; // exact verify
        const rects = BeanMapping.rectsForRange(el, off.start, off.end);
        if (!rects.length) continue;
        // Paragraph = the line (run between newlines); key by line-start offset.
        const lb = text.lastIndexOf("\n", off.start - 1);
        const lineStart = lb < 0 ? 0 : lb + 1;
        const nl = text.indexOf("\n", off.start);
        const paraText = text.slice(lineStart, nl < 0 ? text.length : nl);
        entry = { id: "i" + i++, issue, kind, original: issue.original, rects, start: off.start, end: off.end,
                  lineStart, paraText, sortKey: off.start };
      }
      // Suppress issues in a paragraph Bean just fully proofread (until it changes),
      // so Bean's own correction doesn't look like an endless stream of fixes.
      if (entry.paraText != null && state.correctedFps.has(fingerprint(entry.paraText))) { reason("paragraphSuppressed"); continue; }
      reason("mapUniqueMatch");
      entries.push(entry);
      if (entries.length >= 8) break;
    }
    return entries.sort((a, b) => a.sortKey - b.sortKey);
  }

  // The single safety guard: returns a verified target whose LIVE text equals
  // issue.original, or null. applyIssue only ever acts on this.
  function verifyTarget(el, entry) {
    if (!el || !document.contains(el)) return null;
    if (entry.kind === "ce") {
      const range = BeanMapping.findUniqueRange(el, entry.original);
      if (!range || range.toString() !== entry.original) return null;
      return { kind: "ce", range };
    }
    const v = el.value;
    if (entry.end > v.length || v.slice(entry.start, entry.end) !== entry.original) return null;
    return { kind: "ta", start: entry.start, end: entry.end };
  }

  function recomputeRects() {
    const el = state.active;
    if (!el) return;
    const kept = [];
    for (const entry of state.entries) {
      if (entry.kind === "ce") {
        const range = BeanMapping.findUniqueRange(el, entry.original);
        if (!range || range.toString() !== entry.original) continue; // stale → drop
        const rects = BeanMapping.rectsFromRange(range);
        if (!rects.length) continue;
        entry.rects = rects;
      } else {
        if (el.value.slice(entry.start, entry.end) !== entry.original) continue;
        const rects = BeanMapping.rectsForRange(el, entry.start, entry.end);
        if (!rects.length) continue;
        entry.rects = rects;
      }
      kept.push(entry);
    }
    state.entries = kept;
    if (state.selectedId && !kept.some((e) => e.id === state.selectedId)) state.selectedId = null;
    renderOverlay();
  }

  function dropIssue(id) {
    const i = state.entries.findIndex((e) => e.id === id);
    if (i < 0) return;
    state.entries.splice(i, 1);
    if (!state.entries.length) { clearOverlay(); return; }
    if (state.selectedId === id) state.selectedId = state.entries[Math.min(i, state.entries.length - 1)].id;
    renderOverlay();
  }

  // --- Render + interaction -------------------------------------------------
  function position() {
    if (!state.selectedId) return null;
    const idx = state.entries.findIndex((e) => e.id === state.selectedId);
    return idx >= 0 ? { index: idx, total: state.entries.length } : null;
  }
  // Group issues by paragraph; only paragraphs with >=2 issues AND a reliable
  // anchor get an icon. Recomputed from entries on every render (entries are
  // rebuilt on every map, so group refs never go stale).
  function buildGroups() {
    const el = state.active;
    if (!el) return [];
    const byKey = new Map();
    let gid = 0;
    for (const e of state.entries) {
      const key = e.kind === "ce" ? e.blockEl : (e.lineStart != null ? "L" + e.lineStart : null);
      if (key == null) continue; // ce issue with no block wrapper → not groupable
      let g = byKey.get(key);
      if (!g) { g = { id: "g" + (gid++), kind: e.kind, entries: [] }; byKey.set(key, g); }
      g.entries.push(e);
    }
    const groups = [];
    for (const g of byKey.values()) {
      if (g.entries.length < 2) continue; // single-issue paragraphs get no icon
      const anchor = groupAnchor(el, g);
      if (!anchor) continue;              // unreliable anchor → no icon (never fake)
      g.anchor = anchor;
      g.count = g.entries.length;
      if (g.kind === "ce") {
        g.block = g.entries[0].blockEl;
        // "Fix Paragraph" replaces the whole block's text, so it's only offered
        // when that block is plain text (no links/spans/images to destroy).
        g.canFix = ceBlockReplaceable(g.block);
      } else {
        g.lineStart = g.entries[0].lineStart;
        g.canFix = true;
      }
      groups.push(g);
    }
    return groups;
  }

  // A contenteditable block is safe to fully replace only if its children are all
  // text nodes or <br>; any other element (link/span/image) means replacing the
  // block text would destroy markup, so Fix Paragraph is disabled there.
  function ceBlockReplaceable(block) {
    if (!block || !document.contains(block)) return false;
    for (const node of block.childNodes) {
      if (node.nodeType === 3) continue;                         // text node
      if (node.nodeType === 1 && node.tagName === "BR") continue; // <br>
      return false;
    }
    return true;
  }

  function groupAnchor(el, g) {
    if (g.kind === "ce") {
      const block = g.entries[0].blockEl;
      if (!block || !document.contains(block)) return null;
      const r = block.getBoundingClientRect();
      if (r.width < 1 || r.height < 1) return null;
      return { x: r.left + window.scrollX, y: r.top + window.scrollY, h: Math.min(r.height, 22) };
    }
    const fr = el.getBoundingClientRect();
    const first = g.entries[0].rects[0];
    if (!first || fr.width < 1) return null;
    return { x: fr.left + window.scrollX, y: first.y, h: first.h };
  }

  function renderOverlay() {
    BeanOverlay.render(state.entries, state.selectedId, position(), {
      onActivate: (id) => {
        // Never open a card (and offer Apply) for an unverifiable range.
        const entry = state.entries.find((e) => e.id === id);
        if (!entry) return;
        if (!verifyTarget(state.active, entry)) { reason("applyRangeMismatch"); dropIssue(id); return; }
        state.selectedId = id; state.selectedGroupId = null; renderOverlay();
      },
      onClose: () => { state.selectedId = null; renderOverlay(); },
      onNext: () => {
        reason("buttonNextClicked");
        const idx = state.entries.findIndex((e) => e.id === state.selectedId);
        if (idx < 0 || !state.entries.length) return;
        state.selectedId = state.entries[(idx + 1) % state.entries.length].id;
        renderOverlay();
      },
      onIgnore: (id) => {
        reason("buttonIgnoreClicked");
        const entry = state.entries.find((e) => e.id === id);
        if (entry) state.ignored.add(ignoreKey(entry.issue.original));
        dropIssue(id);
      },
      onApply: (id) => applyIssue(id)
    });

    // Paragraph-level icons + card (priority: an open group card hides the issue
    // card and vice-versa; both live in the same overlay).
    state.groups = buildGroups();
    if (state.selectedGroupId && !state.groups.some((g) => g.id === state.selectedGroupId)) state.selectedGroupId = null;
    reason("paragraphGroupCount:" + state.groups.length);
    BeanOverlay.renderGroups(state.groups, state.selectedGroupId, {
      onActivateGroup: (gid) => {
        const g = state.groups.find((x) => x.id === gid);
        if (!g) return;
        state.selectedGroupId = gid; state.selectedId = null;
        reason("paragraphFixAvailable:" + (g.canFix ? 1 : 0));
        renderOverlay();
      },
      onCloseGroup: () => { state.selectedGroupId = null; renderOverlay(); },
      onReviewGroup: (gid) => {
        reason("paragraphReviewOneByOne");
        const g = state.groups.find((x) => x.id === gid);
        if (!g || !g.entries.length) return;
        const first = g.entries[0];
        state.selectedGroupId = null;
        if (!verifyTarget(state.active, first)) { dropIssue(first.id); return; }
        state.selectedId = first.id; renderOverlay();
      },
      onIgnoreAllGroup: (gid) => {
        reason("paragraphIgnoreAll");
        const g = state.groups.find((x) => x.id === gid);
        if (!g) return;
        const ids = g.entries.map((e) => e.id);
        for (const e of g.entries) state.ignored.add(ignoreKey(e.issue.original));
        state.selectedGroupId = null;
        state.entries = state.entries.filter((e) => !ids.includes(e.id));
        if (!state.entries.length) { clearOverlay(); return; }
        renderOverlay();
      },
      onFixParagraph: (gid) => fixParagraph(gid)
    });
  }

  // Ask the Bean app to proofread a whole paragraph. Resolves to
  // { text: string|null, code }. `text === null` means "use local fallback".
  function bridgeProofreadParagraph(text, fieldType) {
    if (!state.useBridge) return Promise.resolve({ text: null, code: "bridgeFallbackLocal" });
    return new Promise((resolve) => {
      let done = false;
      const finish = (v) => { if (!done) { done = true; reason(v.code); resolve(v); } };
      const timer = setTimeout(() => finish({ text: null, code: "bridgeTimeout" }), 15000);
      try {
        chrome.runtime.sendMessage(
          { type: "proofreadParagraph", request: {
              id: uuid(), type: "proofreadParagraph",
              source: { surface: "browserExtension", urlHost: location.host, fieldType }, text } },
          (resp) => {
            clearTimeout(timer);
            if (!resp) { finish({ text: null, code: "bridgeUnavailable" }); return; }
            if (resp.ok && typeof resp.text === "string") { finish({ text: resp.text, code: "paragraphProofreadSucceeded" }); return; }
            finish({ text: null, code: "bridge_" + (resp.errorCode || "malformed") });
          }
        );
      } catch (e) { clearTimeout(timer); finish({ text: null, code: "bridgeUnavailable" }); }
    });
  }

  // Local fallback: produce a cleaned paragraph using ONLY the offline detector's
  // obvious fixes (typos/spacing). Safe + boundary-preserving on the string.
  function localParagraphFix(paragraph) {
    let p = paragraph;
    const issues = (state.localFallback ? BeanDetector.detect(paragraph) : [])
      .filter((is) => is && typeof is.original === "string" && typeof is.suggestion === "string" &&
                      is.original && is.original !== is.suggestion && !/[\n\r]/.test(is.original));
    // Apply each unique, non-overlapping match end-to-start so offsets stay valid.
    const spans = [];
    for (const is of issues) {
      const off = BeanMapping.uniqueOffset(p, is.original);
      if (!off) continue;
      if (spans.some((s) => off.start < s.end && off.end > s.start)) continue; // overlap → skip
      spans.push({ start: off.start, end: off.end, suggestion: is.suggestion });
    }
    spans.sort((a, b) => b.start - a.start);
    for (const s of spans) {
      const next = BeanMapping.replaceRangePreservingBoundaries(p, s.start, s.end, s.suggestion);
      if (next !== null) p = next;
    }
    return p;
  }

  // Read the live paragraph text + a verifier/replacer for this group. Returns
  // null if the paragraph boundary can't be located safely.
  function paragraphTarget(el, g) {
    if (g.kind === "ce") {
      const block = g.block;
      if (!block || !document.contains(block) || !ceBlockReplaceable(block)) return null;
      return {
        text: block.innerText,
        stillMatches: (sent) => document.contains(block) && block.innerText === sent,
        replace: (corrected) => {
          const range = document.createRange();
          range.selectNodeContents(block);     // whole block, not the editor
          return BeanMapping.applyRange(range, corrected);
        }
      };
    }
    const v = el.value;
    const ls = g.lineStart;
    if (ls == null || ls > v.length) return null;
    const nl = v.indexOf("\n", ls);
    const le = nl < 0 ? v.length : nl;
    return {
      text: v.slice(ls, le),
      stillMatches: (sent) => el.value.slice(ls, le) === sent,
      replace: (corrected) => {
        const cur = el.value;
        // Boundary-preserving splice: only [ls, le) changes; the trailing newline
        // and everything outside stay byte-for-byte identical.
        const next = BeanMapping.replaceRangePreservingBoundaries(cur, ls, le, corrected);
        if (next === null ||
            next.slice(0, ls) !== cur.slice(0, ls) ||
            next.slice(ls + corrected.length) !== cur.slice(le)) {
          return false;
        }
        el.value = next;
        const caret = ls + corrected.length;
        try { el.setSelectionRange(caret, caret); } catch (e) {}
        el.dispatchEvent(new Event("input", { bubbles: true }));
        return true;
      }
    };
  }

  function rememberCorrected(text) {
    state.correctedFps.add(fingerprint(text));
    if (state.correctedFps.size > 32) { // bound the set
      state.correctedFps = new Set(Array.from(state.correctedFps).slice(-16));
    }
  }

  // "Fix Paragraph": proofread and replace the WHOLE paragraph in one pass, so the
  // user never has to apply repeatedly. Safety: verify the paragraph boundary,
  // re-verify it hasn't changed before replacing, preserve everything outside it,
  // sanitize the model output (zero-width / wrappers), and suppress immediate
  // re-detection of the just-corrected paragraph.
  async function fixParagraph(gid) {
    if (state.fixingGroup) return;
    const el = state.active;
    const g = state.groups.find((x) => x.id === gid);
    if (!el || !g || !document.contains(el)) { teardown(); return; }
    if (!g.canFix) { reason("paragraphProofreadUnavailable"); flashAt(g, "Review one by one"); return; }

    const target = paragraphTarget(el, g);
    if (!target) { reason("paragraphReplacementRefused"); flashAt(g, "Review one by one"); return; }
    const sent = target.text;
    if (!sent || !sent.trim() || sent.length > 2000) { reason("paragraphReplacementRefused"); return; }

    state.fixingGroup = true;
    state.selectedGroupId = null;
    reason("paragraphProofreadRequested");
    flashAt(g, "Fixing paragraph…", 4000);

    const fieldType = el.isContentEditable ? "contenteditable" : (el.tagName || "").toLowerCase();
    let bridge;
    try { bridge = await bridgeProofreadParagraph(sent, fieldType); }
    finally { /* fixingGroup cleared below */ }

    // Field/selection may have changed while we waited → bail safely.
    if (el !== state.active || !document.contains(el)) { state.fixingGroup = false; return; }

    let corrected = null, usedFallback = false;
    if (bridge.text !== null) {
      const clean = BeanMapping.sanitizeProofreadParagraphOutput(bridge.text);
      if (clean.zeroWidthStripped > 0) reason("zeroWidthStripped:" + clean.zeroWidthStripped);
      corrected = clean.text;
    } else if (state.localFallback) {
      reason("paragraphProofreadUnavailable");
      const local = localParagraphFix(sent);
      const clean = BeanMapping.sanitizeProofreadParagraphOutput(local);
      corrected = clean.text;
      usedFallback = true;
    }

    state.fixingGroup = false;

    if (corrected === null) { reason("paragraphProofreadUnavailable"); flashAt(g, "Fix Paragraph unavailable"); renderOverlay(); return; }
    if (!corrected.trim()) { reason("paragraphProofreadUnsafeOutput"); flashAt(g, "Couldn't fix paragraph"); renderOverlay(); return; }

    // SAFETY: the paragraph must be byte-for-byte what we sent for proofread.
    if (!target.stillMatches(sent)) { reason("paragraphReplacementRefused"); renderOverlay(); return; }

    if (corrected === sent) {
      // Already clean — just clear this paragraph's issues, no edit.
      reason("paragraphAlreadyClean");
      rememberCorrected(sent);
      const ids = g.entries.map((e) => e.id);
      state.entries = state.entries.filter((e) => !ids.includes(e.id));
      flashAt(g, "Paragraph looks good");
      if (!state.entries.length) { clearOverlay(); return; }
      renderOverlay();
      return;
    }

    if (!target.replace(corrected)) { reason("paragraphReplacementRefused"); renderOverlay(); return; }
    reason("paragraphReplacementVerified");
    reason(usedFallback ? "paragraphProofreadSucceededLocal" : "paragraphProofreadSucceeded");

    // Suppress re-detection of the paragraph we just corrected, drop its issues,
    // and resync fingerprints so we don't immediately re-show the same paragraph.
    rememberCorrected(corrected);
    const ids = g.entries.map((e) => e.id);
    state.entries = state.entries.filter((e) => !ids.includes(e.id));
    const newText = getText(el);
    state.fingerprint = fingerprint(newText);
    state.shownFingerprint = state.fingerprint;
    flashAt(g, "Paragraph fixed");

    // The replace() dispatched input (onInput already cleared + rescheduled). The
    // rescheduled check will suppress the just-fixed paragraph via correctedFps.
  }

  function flashAt(g, msg, ms) {
    if (g && g.anchor) BeanOverlay.flash({ x: g.anchor.x, y: g.anchor.y, h: g.anchor.h || 18 }, msg, ms);
  }

  function applyIssue(id) {
    reason("buttonApplyClicked");
    const el = state.active;
    const entry = state.entries.find((e) => e.id === id);
    if (!el || !entry || !document.contains(el)) { teardown(); return; }

    // SAFETY: only apply to a range whose live text equals issue.original.
    const verified = verifyTarget(el, entry);
    if (!verified) { reason("applyRangeMismatch"); dropIssue(id); return; } // drop, never replace nearby text
    reason("applyVerified");

    // Capture remaining BEFORE editing: the input event clears state.entries.
    const remaining = state.entries.filter((e) => e.id !== id).map((e) => e.issue);

    let ok;
    if (verified.kind === "ce") {
      ok = BeanMapping.applyRange(verified.range, entry.issue.suggestion);
    } else {
      const v = el.value;
      const next = BeanMapping.replaceRangePreservingBoundaries(v, verified.start, verified.end, entry.issue.suggestion);
      // Assert everything outside the replaced range is byte-for-byte unchanged.
      if (next === null || next.slice(0, verified.start) !== v.slice(0, verified.start) ||
          next.slice(verified.start + entry.issue.suggestion.length) !== v.slice(verified.end)) {
        reason("lineBreakRiskRefused"); dropIssue(id); return;
      }
      el.value = next;
      const caret = verified.start + entry.issue.suggestion.length;
      try { el.setSelectionRange(caret, caret); } catch (e) {}
      ok = true;
    }
    if (!ok) { teardown(); return; }
    el.dispatchEvent(new Event("input", { bubbles: true }));
    reason("lineBreakPreserved");
    reason("applySucceeded");

    // Re-map remaining FROM SCRATCH against the new text (no offset shifting, no
    // stale ranges). Drop anything that no longer maps uniquely.
    state.reqGen++;
    const newText = getText(el);
    state.fingerprint = fingerprint(newText);
    state.shownFingerprint = state.fingerprint;
    state.entries = mapEntries(el, newText, remaining);
    if (!state.entries.length) { reason("remapDropped"); clearOverlay(); return; }
    reason("remapSucceeded");
    state.selectedId = state.entries[0].id;
    renderOverlay();
  }

  loadSettings();
})();
