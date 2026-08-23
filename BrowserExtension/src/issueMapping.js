// Bean issue → range mapping. SAFETY-CRITICAL: a fix is only ever applied to a
// range whose live text equals the issue's exact `original`. Highlight rects and
// the apply target always come from the SAME verified range.
//
//   • input / textarea → numeric offsets into element.value (which ARE the real
//     character positions). Apply verifies value.slice(start,end) === original.
//   • contenteditable  → a DOM Range found by searching the element's TEXT NODES
//     (textContent order) for the exact unique `original`. We DO NOT trust
//     innerText offsets (innerText inserts block newlines / normalizes spaces,
//     which diverge from text-node positions — the cause of the corruption).
//     Rects come from range.getClientRects(); apply re-finds + re-verifies the
//     range. Ambiguous (>1) or missing originals are dropped, never applied.
(function () {
  // ---- shared --------------------------------------------------------------
  function clientRectsToPage(list) {
    const out = [];
    for (const r of list) {
      if (r.width < 1 || r.height < 1) continue;
      out.push({ x: r.left + window.scrollX, y: r.top + window.scrollY, w: r.width, h: r.height });
    }
    return out;
  }

  function rectsFromRange(range) {
    try { return clientRectsToPage(range.getClientRects()); } catch (e) { return []; }
  }

  // ---- textarea / input (value offsets) ------------------------------------
  // Returns {start,end} for a UNIQUE occurrence in `text`, or null.
  function uniqueOffset(text, original) {
    if (!original) return null;
    const first = text.indexOf(original);
    if (first < 0) return null;
    if (text.indexOf(original, first + 1) >= 0) return null; // ambiguous
    return { start: first, end: first + original.length };
  }

  function nativeValueSetter(el) {
    const own = Object.getOwnPropertyDescriptor(el, "value");
    let proto = Object.getPrototypeOf(el);
    let inherited = null;
    while (proto && !inherited) {
      const descriptor = Object.getOwnPropertyDescriptor(proto, "value");
      if (descriptor && typeof descriptor.set === "function") inherited = descriptor.set;
      proto = Object.getPrototypeOf(proto);
    }
    // React commonly installs an own value tracker. Calling the native
    // prototype setter bypasses that tracker so the following input event is
    // observed as a real value transition.
    if (inherited && (!own || own.set !== inherited)) return inherited;
    if (own && typeof own.set === "function") return own.set;
    return inherited;
  }

  function editEvent(type, replacement) {
    const options = { bubbles: true, composed: true };
    if (type === "input" && typeof InputEvent === "function") {
      try {
        return new InputEvent("input", {
          ...options,
          inputType: "insertReplacementText",
          data: replacement
        });
      } catch (e) {}
    }
    return new Event(type, options);
  }

  // Replaces an exact range in an input/textarea. `execCommand(insertText)` is
  // attempted first because Chromium records it in native Undo. The fallback
  // uses the prototype value setter required by React-controlled fields, then
  // verifies both input/change delivery and the live value after page handlers.
  function applyTextControlRange(el, start, end, replacement) {
    if (!el || typeof el.value !== "string" || typeof replacement !== "string") {
      return { ok: false, nativeUndoPreserved: false, inputEventVerified: false, changeEventVerified: false };
    }
    const before = el.value;
    const expected = replaceRangePreservingBoundaries(before, start, end, replacement);
    if (expected === null) {
      return { ok: false, nativeUndoPreserved: false, inputEventVerified: false, changeEventVerified: false };
    }

    let inputSeen = false;
    let changeSeen = false;
    const onInput = () => { inputSeen = true; };
    const onChange = () => { changeSeen = true; };
    if (typeof el.addEventListener === "function") {
      el.addEventListener("input", onInput, true);
      el.addEventListener("change", onChange, true);
    }

    let nativeUndoPreserved = false;
    const active = document.activeElement === el;
    if (active && typeof el.setSelectionRange === "function" && typeof document.execCommand === "function") {
      try {
        el.setSelectionRange(start, end);
        nativeUndoPreserved = document.execCommand("insertText", false, replacement) === true
          && el.value === expected;
      } catch (e) { nativeUndoPreserved = false; }
    }

    // A page listener may synchronously rewrite another part of the control in
    // response to execCommand. Never overwrite that newer page/user state with
    // the whole-value fallback; only fall back when the command left the exact
    // pre-edit value untouched.
    const commandLeftUnexpectedValue = el.value !== before && el.value !== expected;
    if (!commandLeftUnexpectedValue && el.value !== expected) {
      try {
        const setter = nativeValueSetter(el);
        if (setter) setter.call(el, expected);
        else el.value = expected;
      } catch (e) {}
    }

    try {
      if (!commandLeftUnexpectedValue && !inputSeen) el.dispatchEvent(editEvent("input", replacement));
      // React and ordinary DOM listeners can synchronously reject/revert the
      // input. Never report success or dispatch change for a reverted value.
      if (!commandLeftUnexpectedValue && el.value === expected && !changeSeen) {
        el.dispatchEvent(editEvent("change", replacement));
      }
    } catch (e) {}

    const ok = el.value === expected && inputSeen && changeSeen;
    if (ok && typeof el.setSelectionRange === "function") {
      const caret = start + replacement.length;
      try { el.setSelectionRange(caret, caret); } catch (e) {}
    }
    if (typeof el.removeEventListener === "function") {
      el.removeEventListener("input", onInput, true);
      el.removeEventListener("change", onChange, true);
    }
    return {
      ok,
      nativeUndoPreserved,
      inputEventVerified: inputSeen,
      changeEventVerified: changeSeen
    };
  }

  let mirror = null;
  function getMirror() {
    if (mirror) return mirror;
    mirror = document.createElement("div");
    mirror.setAttribute("aria-hidden", "true");
    mirror.style.cssText = "position:absolute;visibility:hidden;white-space:pre-wrap;word-wrap:break-word;top:0;left:-9999px;";
    document.body.appendChild(mirror);
    return mirror;
  }
  const COPIED_STYLES = [
    "boxSizing", "width", "paddingTop", "paddingRight", "paddingBottom", "paddingLeft",
    "borderTopWidth", "borderRightWidth", "borderBottomWidth", "borderLeftWidth",
    "fontFamily", "fontSize", "fontWeight", "fontStyle", "letterSpacing",
    "textTransform", "lineHeight", "textIndent"
  ];
  function textareaRects(el, start, end) {
    const cs = window.getComputedStyle(el);
    const m = getMirror();
    COPIED_STYLES.forEach((p) => (m.style[p] = cs[p]));
    m.style.width = el.clientWidth + "px";
    if (el.tagName === "INPUT") { m.style.whiteSpace = "pre"; m.style.wordWrap = "normal"; }
    else { m.style.whiteSpace = "pre-wrap"; m.style.wordWrap = "break-word"; }

    const value = el.value;
    m.textContent = value.slice(0, start);
    const span = document.createElement("span");
    span.textContent = value.slice(start, end) || ".";
    m.appendChild(span);
    m.appendChild(document.createTextNode(value.slice(end)));

    const elRect = el.getBoundingClientRect();
    const mRect = m.getBoundingClientRect();
    const rects = [];
    for (const r of span.getClientRects()) {
      const x = elRect.left + (r.left - mRect.left) - el.scrollLeft;
      const y = elRect.top + (r.top - mRect.top) - el.scrollTop;
      if (r.width < 1 || r.height < 1) continue;
      if (y + r.height < elRect.top || y > elRect.bottom) continue;
      rects.push({ x: x + window.scrollX, y: y + window.scrollY, w: r.width, h: r.height });
    }
    return rects;
  }

  // ---- contenteditable (text-node Range) -----------------------------------
  // Finds the UNIQUE DOM Range whose text equals `original`, searching the
  // element's text nodes in document order. Returns a verified Range or null.
  function findUniqueRange(root, original) {
    if (!original || original.length < 1) return null;
    const segs = [];
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
    let flat = "", node;
    while ((node = walker.nextNode())) {
      segs.push({ node: node, start: flat.length });
      flat += node.nodeValue;
    }
    const first = flat.indexOf(original);
    if (first < 0) return null;                                 // missing
    if (flat.indexOf(original, first + 1) >= 0) return null;    // ambiguous
    const end = first + original.length;

    const locate = (pos) => {
      for (let i = segs.length - 1; i >= 0; i--) {
        if (pos >= segs[i].start) return { node: segs[i].node, offset: pos - segs[i].start };
      }
      return segs.length ? { node: segs[0].node, offset: 0 } : null;
    };
    const a = locate(first), b = locate(end);
    if (!a || !b) return null;
    try {
      const range = document.createRange();
      range.setStart(a.node, a.offset);
      range.setEnd(b.node, b.offset);
      if (range.toString() !== original) return null;           // exact-match guard
      return range;
    } catch (e) { return null; }
  }

  function rangeOffsets(root, range) {
    if (!root || !range || (range.startContainer !== root && !root.contains(range.startContainer)) ||
        (range.endContainer !== root && !root.contains(range.endContainer))) return null;
    try {
      const beforeStart = document.createRange();
      beforeStart.selectNodeContents(root);
      beforeStart.setEnd(range.startContainer, range.startOffset);
      const beforeEnd = document.createRange();
      beforeEnd.selectNodeContents(root);
      beforeEnd.setEnd(range.endContainer, range.endOffset);
      // cloneContents().textContent uses the same flat text-node representation
      // as rangeFromOffsets. Range.toString() can synthesize visual separators
      // around block elements in some editors and would drift from textContent.
      return {
        start: beforeStart.cloneContents().textContent.length,
        end: beforeEnd.cloneContents().textContent.length
      };
    } catch (e) { return null; }
  }

  function rangeFromOffsets(root, start, end) {
    if (!root || start < 0 || end < start) return null;
    const segments = [];
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
    let flatLength = 0, node;
    while ((node = walker.nextNode())) {
      segments.push({ node, start: flatLength, end: flatLength + node.nodeValue.length });
      flatLength += node.nodeValue.length;
    }
    if (end > flatLength || !segments.length) return null;
    const locate = (position, preferPrevious) => {
      for (let i = 0; i < segments.length; i++) {
        const segment = segments[i];
        if (position < segment.end || (position === segment.end && preferPrevious)) {
          return { node: segment.node, offset: position - segment.start };
        }
      }
      const last = segments[segments.length - 1];
      return position === flatLength ? { node: last.node, offset: last.node.nodeValue.length } : null;
    };
    const a = locate(start, false), b = locate(end, true);
    if (!a || !b) return null;
    try {
      const range = document.createRange();
      range.setStart(a.node, a.offset);
      range.setEnd(b.node, b.offset);
      return range;
    } catch (e) { return null; }
  }

  // Applies an exact contenteditable Range while retaining the browser's native
  // Undo entry whenever execCommand is available. The manual DOM fallback is
  // used only when the command left the editor untouched; a partial or
  // unexpected page mutation is refused rather than compounded.
  function applyContentEditableRange(root, range, replacement, expectedText) {
    if (!root || !range || typeof replacement !== "string" || typeof expectedText !== "string") {
      return { ok: false, nativeUndoPreserved: false, inputEventVerified: false, changeEventVerified: false };
    }
    const offsets = rangeOffsets(root, range);
    if (!offsets) {
      return { ok: false, nativeUndoPreserved: false, inputEventVerified: false, changeEventVerified: false };
    }
    const before = root.textContent;
    let inputSeen = false, changeSeen = false;
    const onInput = () => { inputSeen = true; };
    const onChange = () => { changeSeen = true; };
    root.addEventListener("input", onInput, true);
    root.addEventListener("change", onChange, true);

    let nativeUndoPreserved = false;
    try {
      const sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(range);
      if (typeof document.execCommand === "function") {
        nativeUndoPreserved = document.execCommand("insertText", false, replacement) === true &&
          root.textContent === expectedText;
      }
    } catch (e) { nativeUndoPreserved = false; }

    if (root.textContent === before) {
      // A failed command can invalidate/collapse its Range. Rebuild from the
      // captured offsets before taking the narrow DOM fallback.
      const fallbackRange = rangeFromOffsets(root, offsets.start, offsets.end);
      try {
        if (fallbackRange) {
          fallbackRange.deleteContents();
          fallbackRange.insertNode(document.createTextNode(replacement));
        }
      } catch (e) {}
    }

    try {
      if (root.textContent === expectedText && !inputSeen) root.dispatchEvent(editEvent("input", replacement));
      if (root.textContent === expectedText && !changeSeen) root.dispatchEvent(editEvent("change", replacement));
    } catch (e) {}
    const ok = root.textContent === expectedText && inputSeen && changeSeen;
    root.removeEventListener("input", onInput, true);
    root.removeEventListener("change", onChange, true);
    return { ok, nativeUndoPreserved, inputEventVerified: inputSeen, changeEventVerified: changeSeen };
  }

  // Replaces a contenteditable Range with `text`, preserving undo where possible.
  function applyRange(range, text) {
    try {
      const sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(range);
      let ok = false;
      try { ok = document.execCommand("insertText", false, text); } catch (e) {}
      if (!ok) {
        range.deleteContents();
        range.insertNode(document.createTextNode(text));
      }
      return true;
    } catch (e) { return false; }
  }

  // Boundary-preserving splice for value-based fields. Replaces only [start,end)
  // and keeps everything outside it byte-for-byte (newlines, paragraph breaks).
  function lineBreakSignature(value) {
    if (typeof value !== "string") return null;
    return value.match(/\r\n|[\r\n\u2028\u2029]/g) || [];
  }

  function hasMatchingLineBreakStructure(original, replacement) {
    const before = lineBreakSignature(original);
    const after = lineBreakSignature(replacement);
    return !!before && !!after && before.length === after.length
      && before.every((boundary, index) => boundary === after[index]);
  }

  // The replacement must preserve the exact CR/LF boundary sequence inside the
  // selected range too. Returns null on invalid bounds or boundary drift.
  function replaceRangePreservingBoundaries(text, start, end, replacement) {
    if (typeof text !== "string" || typeof replacement !== "string"
        || start < 0 || end > text.length || start > end
        || !hasMatchingLineBreakStructure(text.slice(start, end), replacement)) return null;
    return text.slice(0, start) + replacement + text.slice(end);
  }

  // Cleans a whole-paragraph proofread result before it replaces a paragraph:
  // unwraps ```fences``` / surrounding quotes and removes zero-width artifacts
  // (U+200B/C/D, BOM). Does NOT trim meaningful internal text. Returns
  // { text, zeroWidthStripped } so callers can emit a privacy-safe count.
  function sanitizeProofreadParagraphOutput(output) {
    if (typeof output !== "string") return { text: "", zeroWidthStripped: 0 };
    let s = output;
    // Unwrap a single surrounding fenced block.
    const t = s.trim();
    if (t.startsWith("```")) {
      const lines = t.split("\n");
      if (lines.length >= 2) {
        lines.shift();
        if (lines.length && lines[lines.length - 1].trim() === "```") lines.pop();
        s = lines.join("\n");
      }
    }
    // Unwrap one pair of wrapping quotes if the whole thing is quoted with no
    // interior quote of the same kind.
    const q = s.trim();
    const pairs = [['"', '"'], ["“", "”"], ["‘", "’"]];
    for (const [open, close] of pairs) {
      if (q.length >= 2 && q[0] === open && q[q.length - 1] === close) {
        const inner = q.slice(1, -1);
        if (!inner.includes(open) && !inner.includes(close)) { s = inner; break; }
      }
    }
    // Strip zero-width characters anywhere in the model output (ZWSP, ZWNJ, ZWJ, BOM).
    let zeroWidthStripped = 0;
    s = s.replace(/[\u200B\u200C\u200D\uFEFF]/g, () => { zeroWidthStripped++; return ""; });
    return { text: s, zeroWidthStripped };
  }

  window.BeanMapping = {
    uniqueOffset, applyTextControlRange, textareaRects, rectsFromRange,
    findUniqueRange, rangeOffsets, rangeFromOffsets, applyRange, applyContentEditableRange,
    replaceRangePreservingBoundaries, hasMatchingLineBreakStructure,
    sanitizeProofreadParagraphOutput,
    // back-compat helper used only for textarea/input
    rectsForRange: (el, start, end) => textareaRects(el, start, end)
  };
})();
