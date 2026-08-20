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
  // Returns null on invalid bounds.
  function replaceRangePreservingBoundaries(text, start, end, replacement) {
    if (start < 0 || end > text.length || start > end) return null;
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
    uniqueOffset, textareaRects, rectsFromRange, findUniqueRange, applyRange,
    replaceRangePreservingBoundaries, sanitizeProofreadParagraphOutput,
    // back-compat helper used only for textarea/input
    rectsForRange: (el, start, end) => textareaRects(el, start, end)
  };
})();
