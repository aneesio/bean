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

  // Rich editors insert visual newlines between blocks in innerText. Local
  // findings carry exact rendered offsets; translate them only when removing
  // CR/LF proves both whole-field representations contain the same characters.
  // Space normalization, hidden text, or other differences keep the unique rule.
  function alignTextOffset(nodeText, renderedText, start, end) {
    if (typeof nodeText !== "string" || typeof renderedText !== "string" ||
        !Number.isInteger(start) || !Number.isInteger(end) || start < 0 ||
        end <= start || end > renderedText.length) return null;
    const original = renderedText.slice(start, end);
    if (/[\r\n]/.test(original)) return null;
    if (nodeText === renderedText) return { start, end };
    if (nodeText.replace(/[\r\n]/g, "") !== renderedText.replace(/[\r\n]/g, "")) return null;
    const beforeLength = renderedText.slice(0, start).replace(/[\r\n]/g, "").length;
    let position = 0, count = 0;
    while (position < nodeText.length && count < beforeLength) {
      if (!/[\r\n]/.test(nodeText[position])) count++;
      position++;
    }
    while (position < nodeText.length && /[\r\n]/.test(nodeText[position])) position++;
    return nodeText.slice(position, position + original.length) === original
      ? { start:position, end:position + original.length } : null;
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

  function textControlSelection(el) {
    return Number.isInteger(el.selectionStart) && Number.isInteger(el.selectionEnd) &&
      el.selectionStart >= 0 && el.selectionEnd >= el.selectionStart && el.selectionEnd <= el.value.length
      ? {start:el.selectionStart,end:el.selectionEnd,direction:el.selectionDirection || "none"} : null;
  }

  function contentEditableSelection(root) {
    const selection = window.getSelection();
    if (!selection || selection.rangeCount !== 1) return null;
    const range = selection.getRangeAt(0), offsets = rangeOffsets(root,range);
    if (!offsets) return null;
    const backward = !range.collapsed && selection.anchorNode === range.endContainer && selection.anchorOffset === range.endOffset;
    return {...offsets,direction:backward ? "backward" : "forward",
      startNode:range.startContainer,startOffset:range.startOffset,endNode:range.endContainer,endOffset:range.endOffset,
      startBefore:range.startContainer.nodeType === 1 ? range.startContainer.childNodes[range.startOffset - 1] || null : null,
      startAfter:range.startContainer.nodeType === 1 ? range.startContainer.childNodes[range.startOffset] || null : null,
      endBefore:range.endContainer.nodeType === 1 ? range.endContainer.childNodes[range.endOffset - 1] || null : null,
      endAfter:range.endContainer.nodeType === 1 ? range.endContainer.childNodes[range.endOffset] || null : null};
  }

  function selectionsMatch(a,b) {
    return !!a && !!b && a.start === b.start && a.end === b.end &&
      (a.start === a.end || a.direction === b.direction);
  }

  function domSelectionsMatch(a,b) {
    return selectionsMatch(a,b) && a.startNode === b.startNode && a.startOffset === b.startOffset &&
      a.endNode === b.endNode && a.endOffset === b.endOffset;
  }

  // Map only a selection outside every changed span. A selected rewrite may
  // deliberately collapse into its result; an unrelated typing caret stays put.
  function selectionAfterEdits(selection, edits) {
    if (!selection || !Array.isArray(edits)) return null;
    for (const edit of edits) {
      if (selection.start === selection.end) {
        if (selection.start > edit.start && selection.start < edit.end) return null;
      } else if (edit.start === edit.end
          ? selection.start < edit.start && selection.end > edit.start
          : selection.start < edit.end && selection.end > edit.start) return null;
    }
    const map = (position) => position + edits.reduce((delta,edit) =>
      delta + (position >= edit.end ? edit.replacement.length - (edit.end - edit.start) : 0),0);
    return {...selection,start:map(selection.start),end:map(selection.end)};
  }

  function restoreContentEditableSelection(root, selection) {
    const live = window.getSelection();
    let range = null;
    // Text offsets cannot distinguish before/after a zero-text attachment. Keep
    // the actual element boundary only while both neighbouring child identities
    // still prove it; never project such an endpoint into the nearest text node.
    const endpoint = (node,offset,before,after) => {
      if (!node || !node.isConnected || node !== root && !root.contains(node)) return null;
      if (node.nodeType === 3) return offset <= node.nodeValue.length ? {node,offset} : null;
      if (node.nodeType !== 1) return null;
      const children = Array.from(node.childNodes);
      const previous = before ? children.indexOf(before) : -1;
      const next = after ? children.indexOf(after) : children.length;
      return (before && previous < 0 || after && next < 0 || previous + 1 !== next) ? null : {node,offset:next};
    };
    const start = endpoint(selection.startNode,selection.startOffset,selection.startBefore,selection.startAfter);
    const end = endpoint(selection.endNode,selection.endOffset,selection.endBefore,selection.endAfter);
    if (start && end) {
      try {
        const original = document.createRange();
        original.setStart(start.node,start.offset);original.setEnd(end.node,end.offset);
        if (selectionsMatch({...rangeOffsets(root,original),direction:selection.direction},selection)) range = original;
      } catch (_error) {}
    }
    if (!range && selection.startNode?.nodeType === 3 && selection.endNode?.nodeType === 3) {
      range = rangeFromOffsets(root,selection.start,selection.end,
        {startNode:selection.startNode,endNode:selection.endNode});
    }
    if (!range || !live) return false;
    try {
      if (selection.direction === "backward" && typeof live.setBaseAndExtent === "function") {
        live.setBaseAndExtent(range.endContainer,range.endOffset,range.startContainer,range.startOffset);
      } else { live.removeAllRanges(); live.addRange(range); }
      return selectionsMatch(contentEditableSelection(root),selection);
    } catch (_error) { return false; }
  }

  // Replaces an exact range in an input/textarea. `execCommand(insertText)` is
  // attempted first because Chromium records it in native Undo. The fallback
  // uses the prototype value setter required by React-controlled fields, then
  // verifies both input/change delivery and the live value after page handlers.
  function applyTextControlRange(el, start, end, replacement, options = {}) {
    if (!el || typeof el.value !== "string" || typeof replacement !== "string") {
      return { ok: false, nativeUndoPreserved: false, inputEventVerified: false, changeEventVerified: false };
    }
    const before = el.value;
    const originalSelection = textControlSelection(el), originalFocus = document.activeElement;
    const expected = replaceRangePreservingBoundaries(before, start, end, replacement);
    if (expected === null) {
      return { ok: false, nativeUndoPreserved: false, inputEventVerified: false, changeEventVerified: false };
    }

    const beforeInputs = [];
    const onBeforeInput = (event) => { beforeInputs.push(event); };
    let inputSeen = false;
    let changeSeen = false;
    const onInput = () => { inputSeen = true; };
    const onChange = () => { changeSeen = true; };
    if (typeof el.addEventListener === "function") {
      el.addEventListener("beforeinput", onBeforeInput, true);
      el.addEventListener("input", onInput, true);
      el.addEventListener("change", onChange, true);
    }

    let nativeUndoPreserved = false;
    let commandAttempted = false, commandResult;
    let commandedSelection = null;
    const commandCaret = {start:start + replacement.length,end:start + replacement.length};
    const active = document.activeElement === el;
    if (active && typeof el.setSelectionRange === "function" && typeof document.execCommand === "function") {
      try {
        el.setSelectionRange(start, end);
        commandedSelection = textControlSelection(el);
        commandAttempted = true;
        commandResult = document.execCommand("insertText", false, replacement);
        nativeUndoPreserved = commandResult === true && el.value === expected;
      } catch (e) { nativeUndoPreserved = false; }
    }

    // A page listener may synchronously rewrite another part of the control in
    // response to execCommand. Never overwrite that newer page/user state with
    // the whole-value fallback; only fall back when the command left the exact
    // pre-edit value untouched AND returned a definite no-op without delivering
    // any editing event. A controlled editor can restore that same value while
    // a delivered command is queued; another mutation would duplicate its work.
    const commandLeftUnexpectedValue = el.value !== before && el.value !== expected;
    const noCommandDelivery = (!commandAttempted || commandResult === false) &&
      beforeInputs.length === 0 && !inputSeen && !changeSeen;
    if (noCommandDelivery && el.value === before && el.value !== expected && document.activeElement === originalFocus &&
        (!(commandedSelection || originalSelection) || selectionsMatch(textControlSelection(el),commandedSelection || originalSelection))) {
      try {
        const setter = nativeValueSetter(el);
        if (setter) setter.call(el, expected);
        else el.value = expected;
        // Establish Bean's fallback caret before page input/change callbacks.
        // Afterwards it is merely an ownership check, never an unconditional reset.
        if (el.value === expected && document.activeElement === originalFocus && typeof el.setSelectionRange === "function") {
          el.setSelectionRange(commandCaret.start,commandCaret.end);
        }
      } catch (e) {}
    }

    const commandCancelled = beforeInputs.some((event) => event.defaultPrevented);
    try {
      if (!commandCancelled && !commandLeftUnexpectedValue && el.value === expected && !inputSeen) el.dispatchEvent(editEvent("input", replacement));
      // React and ordinary DOM listeners can synchronously reject/revert the
      // input. Never report success or dispatch change for a reverted value.
      if (!commandCancelled && !commandLeftUnexpectedValue && el.value === expected && !changeSeen) {
        el.dispatchEvent(editEvent("change", replacement));
      }
    } catch (e) {}

    const ok = el.value === expected && inputSeen && changeSeen;
    const selectionOwned = document.activeElement === originalFocus && selectionsMatch(textControlSelection(el),commandCaret);
    const mappedSelection = options.preserveSelection !== false && selectionAfterEdits(originalSelection,[{start,end,replacement}]);
    let selectionPreserved = false;
    if (ok && selectionOwned && mappedSelection && typeof el.setSelectionRange === "function") {
      try {
        el.setSelectionRange(mappedSelection.start,mappedSelection.end,mappedSelection.direction);
        selectionPreserved = selectionsMatch(textControlSelection(el),mappedSelection);
      } catch (e) {}
    }
    if (typeof el.removeEventListener === "function") {
      el.removeEventListener("beforeinput", onBeforeInput, true);
      el.removeEventListener("input", onInput, true);
      el.removeEventListener("change", onChange, true);
    }
    return {
      ok,
      nativeUndoPreserved,
      selectionOwned, selectionPreserved,
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

  function rangeFromOffsets(root, start, end, options = {}) {
    if (!root || start < 0 || end < start) return null;
    const segments = [];
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
    let flatLength = 0, node;
    while ((node = walker.nextNode())) {
      segments.push({ node, start: flatLength, end: flatLength + node.nodeValue.length });
      flatLength += node.nodeValue.length;
    }
    if (end > flatLength || !segments.length) return null;
    const locate = (position, preferPrevious, preferredNode) => {
      const preferred = segments.find((segment) => segment.node === preferredNode && position >= segment.start && position <= segment.end);
      if (preferred) return {node:preferred.node,offset:position - preferred.start};
      for (let i = 0; i < segments.length; i++) {
        const segment = segments[i];
        if (position < segment.end || (position === segment.end && preferPrevious)) {
          return { node: segment.node, offset: position - segment.start };
        }
      }
      const last = segments[segments.length - 1];
      return position === flatLength ? { node: last.node, offset: last.node.nodeValue.length } : null;
    };
    let a = locate(start, false,options.startNode), b = start === end ? a : locate(end, true,options.endNode);
    if (start === end) {
      const candidates = segments.filter((segment) => segment.node.nodeValue.length > 0 && start >= segment.start && start <= segment.end);
      if (candidates.length > 1) {
        const preferred = candidates.find((segment) => segment.node === options.startNode && segment.node === options.endNode);
        const scoped = options.scopeRoot && candidates.filter((segment) => options.scopeRoot.contains(segment.node));
        const known = preferred || scoped && scoped.length === 1 && scoped[0];
        if (!known) return null; // Flat text cannot tell two paragraph/style boundaries apart.
        a = b = {node:known.node,offset:start - known.start};
      }
    }
    if (!a || !b) return null;
    if (options.scopeRoot && (!root.contains(options.scopeRoot) && root !== options.scopeRoot ||
        !options.scopeRoot.contains(a.node) || !options.scopeRoot.contains(b.node))) return null;
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
  function applyContentEditableRange(root, range, replacement, expectedText, options = {}) {
    if (!root || !range || typeof replacement !== "string" || typeof expectedText !== "string") {
      return { ok: false, nativeUndoPreserved: false, inputEventVerified: false, changeEventVerified: false };
    }
    const offsets = rangeOffsets(root, range);
    if (!offsets) {
      return { ok: false, nativeUndoPreserved: false, inputEventVerified: false, changeEventVerified: false };
    }
    const before = root.textContent;
    const sourceStartNode = range.startContainer, sourceEndNode = range.endContainer;
    const originalSelection = contentEditableSelection(root), originalFocus = document.activeElement;
    let commandCaret = {start:offsets.start + replacement.length,end:offsets.start + replacement.length,
      startNode:range.startContainer,endNode:range.startContainer,
      startOffset:range.startOffset + replacement.length,endOffset:range.startOffset + replacement.length};
    let commandedSelection = null;
    const beforeInputs = [];
    const onBeforeInput = (event) => { beforeInputs.push(event); };
    let inputSeen = false, changeSeen = false;
    const onInput = () => { inputSeen = true; };
    const onChange = () => { changeSeen = true; };
    root.addEventListener("beforeinput", onBeforeInput, true);
    root.addEventListener("input", onInput, true);
    root.addEventListener("change", onChange, true);

    let nativeUndoPreserved = false;
    let commandAttempted = false, commandResult;
    try {
      const sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(range);
      commandedSelection = contentEditableSelection(root);
      if (typeof document.execCommand === "function") {
        commandAttempted = true;
        commandResult = document.execCommand("insertText", false, replacement);
        nativeUndoPreserved = commandResult === true && root.textContent === expectedText;
      }
    } catch (e) { nativeUndoPreserved = false; }

    const noCommandDelivery = (!commandAttempted || commandResult === false) &&
      beforeInputs.length === 0 && !inputSeen && !changeSeen;
    if (noCommandDelivery && root.textContent === before && document.activeElement === originalFocus &&
        (sourceStartNode === root || root.contains(sourceStartNode)) &&
        (sourceEndNode === root || root.contains(sourceEndNode)) &&
        domSelectionsMatch(contentEditableSelection(root),commandedSelection)) {
      // A failed command can invalidate/collapse its Range. Rebuild from the
      // captured offsets before taking the narrow DOM fallback.
      const fallbackRange = rangeFromOffsets(root, offsets.start, offsets.end,
        {startNode:sourceStartNode,endNode:sourceEndNode});
      try {
        if (fallbackRange) {
          fallbackRange.deleteContents();
          const node = document.createTextNode(replacement);
          fallbackRange.insertNode(node);
          const caret = document.createRange(); caret.setStart(node,node.nodeValue.length); caret.collapse(true);
          const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(caret);
          commandCaret = contentEditableSelection(root);
        }
      } catch (e) {}
    }

    const commandCancelled = beforeInputs.some((event) => event.defaultPrevented);
    try {
      if (!commandCancelled && root.textContent === expectedText && !inputSeen) root.dispatchEvent(editEvent("input", replacement));
      if (!commandCancelled && root.textContent === expectedText && !changeSeen) root.dispatchEvent(editEvent("change", replacement));
    } catch (e) {}
    const ok = root.textContent === expectedText && inputSeen && changeSeen;
    const selectionOwned = document.activeElement === originalFocus && domSelectionsMatch(contentEditableSelection(root),commandCaret);
    const mappedSelection = options.preserveSelection !== false && selectionAfterEdits(originalSelection,
      [{start:offsets.start,end:offsets.end,replacement}]);
    const selectionPreserved = !!(ok && selectionOwned && mappedSelection && restoreContentEditableSelection(root,mappedSelection));
    root.removeEventListener("beforeinput", onBeforeInput, true);
    root.removeEventListener("input", onInput, true);
    root.removeEventListener("change", onChange, true);
    return { ok, nativeUndoPreserved, selectionOwned, selectionPreserved,
      inputEventVerified: inputSeen, changeEventVerified: changeSeen };
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
  // (new U+200B/BOM artifacts). Joiners carry emoji and language structure.
  // Does NOT trim meaningful internal text. Returns
  // { text, zeroWidthStripped } so callers can emit a privacy-safe count.
  function sanitizeProofreadParagraphOutput(output, original = "") {
    if (typeof output !== "string") return { text: "", zeroWidthStripped: 0 };
    let s = output;
    const source = typeof original === "string" ? original.trim() : "";
    // Unwrap a single surrounding fenced block.
    const t = s.trim();
    if (t.startsWith("```") && !source.startsWith("```")) {
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
    const pairs = [['"', '"'], ["'", "'"], ["“", "”"], ["‘", "’"], ["«", "»"]];
    const sourceQuoted = pairs.some(([open,close]) => source.startsWith(open) && source.endsWith(close) && source.length >= 2);
    for (const [open, close] of pairs) {
      if (!sourceQuoted && q.length >= 2 && q[0] === open && q[q.length - 1] === close) {
        const inner = q.slice(1, -1);
        if (!inner.includes(open) && !inner.includes(close)) { s = inner; break; }
      }
    }
    // ZWJ/ZWNJ are meaningful in emoji and many languages. Existing invisible
    // separators also belong to the user's text and must survive proofreading.
    let zeroWidthStripped = 0;
    s = s.replace(/[\u200B\uFEFF]/g, (character) => {
      if (typeof original === "string" && original.includes(character)) return character;
      zeroWidthStripped++; return "";
    });
    return { text: s, zeroWidthStripped };
  }

  // Bounded token diff, trimmed at grapheme boundaries. Every offset refers to
  // the captured UTF-16 string, never innerText or a fuzzy search.
  function validateEditPlan(original, edits) {
    if (typeof original !== "string" || !Array.isArray(edits) || edits.length > 64 ||
        typeof Intl.Segmenter !== "function") return null;
    const boundaries = new Set([0, original.length]);
    for (const segment of new Intl.Segmenter(undefined, {granularity:"grapheme"}).segment(original)) boundaries.add(segment.index);
    const sorted = edits.map((edit) => ({...edit})).sort((a,b) => a.start - b.start);
    let previous = null;
    for (const edit of sorted) {
      if (!Number.isInteger(edit.start) || !Number.isInteger(edit.end) || edit.start < 0 || edit.end < edit.start ||
          edit.end > original.length || !boundaries.has(edit.start) || !boundaries.has(edit.end) ||
          typeof edit.original !== "string" || typeof edit.replacement !== "string" ||
          original.slice(edit.start,edit.end) !== edit.original || edit.original === edit.replacement ||
          /[\r\n\u2028\u2029\ufffc]/u.test(edit.original + edit.replacement) ||
          previous && (previous.end > edit.start || previous.start === edit.start)) return null;
      previous = edit;
    }
    let replacement = original;
    for (const edit of [...sorted].reverse()) replacement = replacement.slice(0,edit.start) + edit.replacement + replacement.slice(edit.end);
    return {original,replacement,edits:sorted};
  }

  function buildMinimalEditPlan(original, corrected) {
    if (typeof original !== "string" || typeof corrected !== "string" || original.length > 50000 ||
        corrected.length > 50000 || typeof Intl.Segmenter !== "function") return null;
    if (original === corrected) return validateEditPlan(original,[]);
    const segmenter = new Intl.Segmenter(undefined,{granularity:"grapheme"});
    const characters = (text) => Array.from(segmenter.segment(text),(part) => part.segment);
    // Rich block boundaries are absent from textContent. Retain substantial
    // unchanged character anchors inside a changed token run, while keeping
    // short transpositions together so they cannot move letters between styles.
    let refinementBudget = 2000000;
    const refine = (start,removed,inserted) => {
      const old = characters(removed), next = characters(inserted), columns = next.length + 1;
      const cells = (old.length + 1) * columns;
      if (cells > refinementBudget) return null;
      refinementBudget -= cells;
      const lcs = new Uint32Array(cells);
      for (let i = old.length - 1; i >= 0; i--) for (let j = next.length - 1; j >= 0; j--) {
        lcs[i * columns + j] = old[i] === next[j] ? 1 + lcs[(i + 1) * columns + j + 1]
          : Math.max(lcs[(i + 1) * columns + j],lcs[i * columns + j + 1]);
      }
      const result = []; let i = 0, j = 0, offset = start, runStart = start, prior = "", replacement = "";
      const flush = () => {
        if (prior !== replacement) result.push({start:runStart,end:runStart + prior.length,original:prior,replacement});
        prior = ""; replacement = ""; runStart = offset;
      };
      while (i < old.length || j < next.length) {
        if (i < old.length && j < next.length && old[i] === next[j]) {
          let length = 0;
          while (i + length < old.length && j + length < next.length && old[i + length] === next[j + length]) length++;
          const anchor = old.slice(i,i + length).join("");
          if (length >= 3) { flush(); offset += anchor.length; runStart = offset; }
          else { prior += anchor; replacement += anchor; offset += anchor.length; }
          i += length; j += length;
        } else if (i < old.length && (j === next.length || lcs[(i + 1) * columns + j] >= lcs[i * columns + j + 1])) {
          prior += old[i]; offset += old[i++].length;
        } else replacement += next[j++];
      }
      flush();
      return result;
    };
    const tokens = (text) => {
      const result = []; let category = -1;
      for (const character of characters(text)) {
        const next = /[\r\n\u2028\u2029]/u.test(character) ? 3 : /^[\p{L}\p{N}]/u.test(character) ? 0 : /^\s/u.test(character) ? 1 : 2;
        if (!result.length || category !== next || next >= 2) result.push(character);
        else result[result.length - 1] += character;
        category = next;
      }
      return result;
    };
    const before = tokens(original), after = tokens(corrected);
    let prefix = 0, suffix = 0;
    while (prefix < Math.min(before.length,after.length) && before[prefix] === after[prefix]) prefix++;
    while (suffix < Math.min(before.length,after.length) - prefix && before[before.length - suffix - 1] === after[after.length - suffix - 1]) suffix++;
    const left = before.slice(prefix,before.length - suffix), right = after.slice(prefix,after.length - suffix);
    const columns = right.length + 1, cells = (left.length + 1) * columns;
    if (cells > 2000000) return null;
    const lcs = new Uint32Array(cells);
    for (let i = left.length - 1; i >= 0; i--) for (let j = right.length - 1; j >= 0; j--) {
      lcs[i * columns + j] = left[i] === right[j] ? 1 + lcs[(i + 1) * columns + j + 1]
        : Math.max(lcs[(i + 1) * columns + j], lcs[i * columns + j + 1]);
    }
    let offset = before.slice(0,prefix).join("").length, i = 0, j = 0; const edits = [];
    while (i < left.length || j < right.length) {
      if (i < left.length && j < right.length && left[i] === right[j]) {offset += left[i++].length; j++; continue;}
      const start = offset; let removed = "", inserted = "";
      while (i < left.length || j < right.length) {
        if (i < left.length && j < right.length && left[i] === right[j]) break;
        if (i < left.length && (j === right.length || lcs[(i + 1) * columns + j] >= lcs[i * columns + j + 1])) {
          removed += left[i]; offset += left[i++].length;
        } else inserted += right[j++];
      }
      const oldChars = characters(removed), newChars = characters(inserted); let p = 0, s = 0;
      while (p < Math.min(oldChars.length,newChars.length) && oldChars[p] === newChars[p]) p++;
      while (s < Math.min(oldChars.length,newChars.length) - p && oldChars[oldChars.length - s - 1] === newChars[newChars.length - s - 1]) s++;
      const trimmed = oldChars.slice(p,oldChars.length - s).join(""), shift = oldChars.slice(0,p).join("").length;
      const refined = refine(start + shift,trimmed,newChars.slice(p,newChars.length - s).join(""));
      if (!refined) return null;
      edits.push(...refined);
      if (edits.length > 64) return null;
    }
    const plan = validateEditPlan(original,edits);
    return plan && plan.replacement === corrected ? plan : null;
  }

  function inverseEditPlan(plan) {
    const edits = []; let delta = 0;
    for (const edit of plan.edits) {
      const next = {start:edit.start + delta,end:edit.start + delta + edit.replacement.length,
        original:edit.replacement,replacement:edit.original};
      delta += edit.replacement.length - (edit.end - edit.start);
      const prior = edits[edits.length - 1];
      if (prior && prior.start === next.start) {
        prior.end += next.original.length; prior.original += next.original; prior.replacement += next.replacement;
      } else edits.push(next);
    }
    return validateEditPlan(plan.replacement,edits);
  }

  // Mechanical corrections stay inside one text node. A change crossing a
  // formatting/atomic boundary is declined before sending any edit.
  function applyContentEditableEdits(root, candidate, options = {}) {
    const fail = (text, confirmedEdits = []) => {
      const applied = candidate && validateEditPlan(candidate.original,confirmedEdits);
      return {ok:false,confirmedText:text,confirmedEdits,partial:confirmedEdits.length > 0,nativeUndoPreserved:false,
        undoPlan:confirmedEdits.length > 0 && applied && applied.replacement === text ? inverseEditPlan(applied) : null};
    };
    const plan = candidate && validateEditPlan(candidate.original,candidate.edits);
    const valid = () => root && root.isConnected && root.isContentEditable &&
      (!options.scopeRoot || options.scopeRoot.isConnected && (options.scopeRoot === root || root.contains(options.scopeRoot))) &&
      (!options.validateDestination || options.validateDestination());
    if (!plan || plan.replacement !== candidate.replacement || !valid() || root.textContent !== plan.original) return fail(root && root.textContent);
    const safeRange = (range) => range && range.startContainer === range.endContainer && range.startContainer.nodeType === 3 &&
      !range.startContainer.parentElement.closest('[contenteditable="false"],script,style,code,pre');
    for (const edit of plan.edits) if (!safeRange(rangeFromOffsets(root,edit.start,edit.end,{scopeRoot:options.scopeRoot}))) return fail(root.textContent);
    const originalSelection = contentEditableSelection(root), originalFocus = document.activeElement;
    const mappedSelection = options.preserveSelection !== false && selectionAfterEdits(originalSelection,plan.edits);
    let expected = plan.original, nativeUndoPreserved = true, selectionOwned = false;
    const confirmedEdits = [], ordered = [...plan.edits].reverse();
    for (const [index,edit] of ordered.entries()) {
      if (!valid() || root.textContent !== expected) return fail(root.textContent,confirmedEdits);
      const range = rangeFromOffsets(root,edit.start,edit.end,{scopeRoot:options.scopeRoot});
      if (!safeRange(range) || range.toString() !== edit.original) return fail(root.textContent,confirmedEdits);
      expected = expected.slice(0,edit.start) + edit.replacement + expected.slice(edit.end);
      const result = applyContentEditableRange(root,range,edit.replacement,expected,{preserveSelection:false});
      if (!result.ok) return fail(root.textContent,confirmedEdits);
      nativeUndoPreserved = nativeUndoPreserved && result.nativeUndoPreserved;
      confirmedEdits.push(edit);
      selectionOwned = result.selectionOwned;
      if (index < ordered.length - 1 && (!selectionOwned || !valid())) return fail(root.textContent,confirmedEdits);
    }
    const selectionPreserved = !!(mappedSelection && selectionOwned && document.activeElement === originalFocus && valid() &&
      root.textContent === plan.replacement && restoreContentEditableSelection(root,mappedSelection));
    return {ok:root.textContent === plan.replacement,confirmedText:root.textContent,confirmedEdits,partial:false,
      nativeUndoPreserved,selectionPreserved,undoPlan:inverseEditPlan(plan)};
  }

  window.BeanMapping = {
    validateEditPlan, buildMinimalEditPlan, inverseEditPlan, applyContentEditableEdits,
    selectionAfterEdits,
    uniqueOffset, alignTextOffset, applyTextControlRange, textareaRects, rectsFromRange,
    findUniqueRange, rangeOffsets, rangeFromOffsets, applyRange, applyContentEditableRange,
    replaceRangePreservingBoundaries, hasMatchingLineBreakStructure,
    sanitizeProofreadParagraphOutput,
    // back-compat helper used only for textarea/input
    rectsForRange: (el, start, end) => textareaRects(el, start, end)
  };
})();
