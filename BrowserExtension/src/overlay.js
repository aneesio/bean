// Bean's web overlay. It uses semantic controls inside an isolated Shadow DOM,
// preserves the source field during pointer interaction, and exposes explicit
// Undo / re-enable contracts for the content-script replacement pipeline.
(function () {
  const ACCENT = "#8a4c17";
  const DARK_ACCENT = "#e0a15e";
  let hostEl = null, shadow = null, underlineLayer = null, cardEl = null, hoverTimer = null;
  let groupLayer = null, groupCardEl = null, liveRegion = null;
  let paragraphReviewEl = null, paragraphReviewShield = null;
  let paragraphReviewResolve = null, paragraphBusyEl = null;
  let undoEl = null, undoTimer = null, fieldDisabledEl = null;
  let keyboardActivationPending = false, keyboardActivationTimer = null;
  let keyboardExitHandler = null, assistantEl = null, assistantCardEl = null;
  let assistantCardState = null;
  let assistantPlacementState = null;
  const ASSISTANT_TARGET_SIZE = 28;
  const ASSISTANT_GAP = 4;
  const ASSISTANT_OBSTACLES = 'button,input,textarea,select,a[href],label,summary,iframe,[role="button"],[role="link"],[role="textbox"],[role="checkbox"],[role="combobox"],[role="slider"],[role="menuitem"],[contenteditable]:not([contenteditable="false"]),[tabindex],[onclick],[onmousedown],[draggable="true"],video[controls],audio[controls]';

  function officialMarkURL() {
    try {
      return typeof chrome !== "undefined" && chrome.runtime && chrome.runtime.getURL
        ? chrome.runtime.getURL("icon128.png")
        : "icon128.png";
    } catch (_error) {
      return "icon128.png";
    }
  }

  function ensureHost() {
    if (hostEl) return;
    hostEl = document.createElement("div");
    hostEl.id = "bean-inline-host";
    hostEl.dataset.bean = "overlay";
    hostEl.dataset.beanOverlay = "";
    hostEl.style.cssText = "position:absolute;top:0;left:0;width:0;height:0;z-index:2147483646;";
    // Keep actionable Bean controls unreachable from the host page. With an
    // open root, page JavaScript could query our Apply/AI buttons and invoke
    // them without a user gesture after the user typed. Bean retains this
    // closed root directly, while native keyboard and accessibility activation
    // continue to work normally inside it.
    shadow = hostEl.attachShadow({ mode: "closed" });
    shadow.addEventListener("keydown", (event) => {
      const controls = keyboardControls();
      const direction = keyboardExitDirection(event, controls, shadow.activeElement);
      if (direction === 0) return;
      event.stopPropagation();
      // Backward exit is an explicit handoff to the source and therefore
      // cancels this Tab. Forward exit restores the source and removes Bean's
      // bridge, but deliberately leaves Tab uncancelled so the browser—not Bean—
      // computes the next sequential focus target.
      if (direction < 0) event.preventDefault();
      if (typeof keyboardExitHandler === "function") {
        keyboardExitHandler(direction);
      }
    });
    const style = document.createElement("style");
    style.textContent = `
      :host { color-scheme:light dark; --bean-accent:${ACCENT}; --bean-ink:#252321;
              --bean-muted:#66615c; --bean-issue:#D97706; --bean-surface:rgba(255,253,250,.98); --bean-line:#d8d1c9; }
      * { box-sizing:border-box; }
      .layer { position:absolute; top:0; left:0; pointer-events:none; }
      button { font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
      button:focus-visible { outline:3px solid var(--bean-accent); outline-offset:2px; }
      .ul { position:absolute; pointer-events:auto; cursor:pointer; margin:0; padding:0;
            border:0; border-bottom:2px solid var(--bean-accent); background:transparent; box-sizing:border-box; }
      .ul:hover,.ul:focus-visible { background:color-mix(in srgb,var(--bean-accent) 10%,transparent); }
      .card { position:absolute; pointer-events:auto; width:min(300px,calc(100vw - 16px));
              max-height:calc(100vh - 16px); overflow:auto; overscroll-behavior:contain;
              font:13px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
              background:var(--bean-surface); color:var(--bean-ink); border:1px solid var(--bean-line);
              border-radius:13px; box-shadow:0 12px 32px rgba(0,0,0,.2); padding:13px; }
      .row { display:flex; align-items:center; gap:7px; }
      .pill { font-size:11px; color:var(--bean-muted); }
      .x,.more { display:inline-flex; align-items:center; justify-content:center; width:32px; height:32px;
                 margin-left:auto; cursor:pointer; color:var(--bean-muted); border:0; border-radius:8px; background:transparent; font-size:14px; }
      .x:hover,.more:hover { color:var(--bean-accent); background:color-mix(in srgb,var(--bean-accent) 10%,transparent); }
      .fix { overflow-wrap:anywhere; font-size:14px; margin:9px 0 11px; }
      .orig { color:var(--bean-muted); text-decoration:line-through; }
      .arrow { color:var(--bean-muted); margin:0 6px; }
      .sugg { color:var(--bean-accent); font-weight:650; }
      .expl { font-size:11px; color:var(--bean-muted); margin:6px 0 9px; }
      .actions { display:flex; gap:7px; align-items:center; }
      .alternatives { flex-wrap:wrap; margin-bottom:8px; }
      .alternatives button.b { min-width:0; max-width:100%; overflow-wrap:anywhere; }
      .spacer { flex:1; }
      button.b { min-height:32px; border-radius:8px; border:1px solid var(--bean-line);
                 background:var(--bean-surface); color:var(--bean-ink); padding:5px 10px; cursor:pointer; font-size:12px; }
      button.b:hover { border-color:var(--bean-accent); }
      button.primary { background:var(--bean-accent); color:#fff; border-color:var(--bean-accent); font-weight:650; }
      button.b:disabled { opacity:.45; cursor:default; }
      .pico { position:absolute; pointer-events:auto; cursor:pointer; width:30px; height:30px; padding:2px;
              border-radius:9px; background:var(--bean-surface); border:1px solid var(--bean-line);
              box-shadow:0 2px 8px rgba(0,0,0,.2); box-sizing:border-box; }
      .assistant { position:absolute; display:flex; align-items:center; justify-content:center;
                   width:28px; height:28px; padding:0; pointer-events:auto; cursor:pointer;
                   appearance:none; border:0; border-radius:0; background:transparent; color:var(--bean-muted); }
      .assistant::before { content:""; position:absolute; inset:0; border-radius:50%; pointer-events:none; }
      .assistant-dot { display:block; width:10px; height:10px; flex:none; border:1.5px solid currentColor;
                       border-radius:50%; background:transparent; pointer-events:none; }
      .assistant[data-has-issues="true"] .assistant-dot { border-color:var(--bean-issue); background:var(--bean-issue); }
      .assistant:hover::before { background:color-mix(in srgb,var(--bean-accent) 10%,transparent); }
      .source { font-size:10px; color:var(--bean-muted); margin:0 0 5px; }
      .pico img { display:block; width:24px; height:24px; border-radius:7px; }
      .pico:hover { border-color:var(--bean-accent); transform:translateY(-1px); }
      .gactions { display:flex; gap:7px; flex-wrap:wrap; margin-top:8px; }
      .gactions[hidden] { display:none; }
      .scope { display:flex; gap:3px; margin:10px 0; padding:3px; border:1px solid var(--bean-line); border-radius:9px; }
      .scope[hidden] { display:none; }
      .scope button { flex:1; min-height:32px; border:0; border-radius:6px; background:transparent; color:var(--bean-ink); cursor:pointer; font-size:11px; }
      .scope button[aria-pressed="true"] { background:color-mix(in srgb,var(--bean-accent) 14%,transparent); font-weight:650; }
      .overflow-wrap { position:relative; margin-left:auto; }
      .overflow-menu { position:absolute; right:0; bottom:38px; z-index:2; width:210px; padding:5px;
                       border:1px solid var(--bean-line); border-radius:10px; background:var(--bean-surface);
                       box-shadow:0 10px 24px rgba(0,0,0,.18); }
      .overflow-menu[hidden] { display:none; }
      .overflow-menu button { display:block; width:100%; min-height:34px; padding:7px 9px; border:0; border-radius:7px;
                              background:transparent; color:var(--bean-ink); text-align:left; cursor:pointer; font-size:12px; }
      .overflow-menu button:hover,.overflow-menu button:focus-visible { background:color-mix(in srgb,var(--bean-accent) 11%,transparent); }
      .modal-shield { position:fixed; inset:0; pointer-events:auto; background:transparent; }
      .review { z-index:1; width:min(560px,calc(100vw - 16px)); }
      .compare { display:grid; grid-template-columns:1fr 1fr; gap:9px; margin:8px 0 11px; }
      .compare label { display:block; font-size:10px; font-weight:650; color:var(--bean-muted); margin-bottom:4px; }
      .compare pre { box-sizing:border-box; height:150px; overflow:auto; white-space:pre-wrap; overflow-wrap:anywhere;
                     margin:0; padding:9px; border-radius:8px; background:color-mix(in srgb,var(--bean-ink) 5%,transparent);
                     border:1px solid var(--bean-line); font:13px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
      .diff-remove { background:color-mix(in srgb,#bd514c 17%,transparent); text-decoration:line-through; border-radius:2px; }
      .diff-add { background:color-mix(in srgb,#30956b 20%,transparent); border-radius:2px; }
      .toast { position:fixed; right:16px; bottom:16px; pointer-events:auto; display:flex; align-items:center; gap:12px;
               min-width:220px; max-width:min(380px,calc(100vw - 32px)); padding:10px 11px 10px 13px;
               border:1px solid var(--bean-line); border-radius:12px; background:var(--bean-surface); color:var(--bean-ink);
               box-shadow:0 12px 30px rgba(0,0,0,.22); font:13px/1.35 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
      .toast strong { flex:1; font-weight:600; }
      .toast button { min-width:58px; min-height:32px; border:0; border-radius:8px; background:transparent;
                      color:var(--bean-accent); cursor:pointer; font-weight:700; }
      .toast button:hover { background:color-mix(in srgb,var(--bean-accent) 11%,transparent); }
      .live { position:fixed; width:1px; height:1px; margin:-1px; overflow:hidden; clip-path:inset(50%); white-space:nowrap; }
      @media (max-width:620px) { .compare { grid-template-columns:1fr; } .compare pre { height:100px; } }
      @media (prefers-color-scheme:dark) {
        :host { --bean-accent:${DARK_ACCENT}; --bean-ink:#f2efeb; --bean-muted:#c4bdb5;
                --bean-issue:#FBBF24; --bean-surface:rgba(41,38,34,.98); --bean-line:#59514a; }
        button.primary { color:#21160d; }
      }
      @media (prefers-reduced-motion:reduce) { .pico:hover { transform:none; } * { transition:none !important; } }
      @media (forced-colors:active) { .card,.pico,.toast,button.b,.overflow-menu { border:1px solid CanvasText; }
                                     .assistant-dot { border-color:ButtonText; }
                                     .assistant[data-has-issues="true"] .assistant-dot { border-color:Highlight; background:Highlight; }
                                     .ul { border-bottom:3px solid LinkText; } }
    `;
    underlineLayer = document.createElement("div");
    underlineLayer.className = "layer";
    groupLayer = document.createElement("div");
    groupLayer.className = "layer";
    liveRegion = document.createElement("div");
    liveRegion.className = "live";
    liveRegion.setAttribute("role", "status");
    liveRegion.setAttribute("aria-live", "polite");
    shadow.append(style, underlineLayer, groupLayer, liveRegion);
    document.body.appendChild(hostEl);
  }

  function announce(message) {
    ensureHost();
    liveRegion.textContent = "";
    setTimeout(() => { if (liveRegion) liveRegion.textContent = message; }, 0);
  }

  function call(handlers, name, ...args) {
    if (handlers && typeof handlers[name] === "function") return handlers[name](...args);
  }

  function isPlainTabEvent(event) {
    return !!event && event.key === "Tab" && !event.defaultPrevented &&
      !event.ctrlKey && !event.metaKey && !event.altKey && !event.isComposing;
  }

  // Keep the normal page tab order usable while the actionable overlay lives
  // in a closed Shadow DOM. The content script inserts a zero-size focus bridge
  // immediately after the active editor; that bridge can focus the first Bean
  // control, while this boundary callback returns to the editor or advances to
  // the next page control. Page scripts still cannot query or click Apply/AI.
  function keyboardScope() {
    if (paragraphReviewEl) return paragraphReviewEl;
    if (paragraphBusyEl) return paragraphBusyEl;
    if (assistantCardEl) return assistantCardEl;
    if (cardEl) return cardEl;
    if (groupCardEl) return groupCardEl;
    return shadow;
  }

  function keyboardControls() {
    if (!shadow) return [];
    const scope = keyboardScope();
    return [...scope.querySelectorAll("button")].filter((button) =>
      !button.disabled && !button.closest("[hidden]") &&
      button.getAttribute("aria-hidden") !== "true"
    );
  }

  function keyboardExitDirection(event, controls, active) {
    if (!isPlainTabEvent(event) || !controls || !controls.length) return 0;
    if (event.shiftKey && active === controls[0]) return -1;
    if (!event.shiftKey && active === controls[controls.length - 1]) return 1;
    return 0;
  }

  function focusFirstControl() {
    ensureHost();
    const control = keyboardControls()[0];
    if (!control) return false;
    control.focus();
    return shadow.activeElement === control;
  }

  function focusLastControl() {
    ensureHost();
    const controls = keyboardControls();
    const control = controls[controls.length - 1];
    if (!control) return false;
    control.focus();
    return shadow.activeElement === control;
  }

  function hasKeyboardControls() {
    return keyboardControls().length > 0;
  }

  function setKeyboardExitHandler(handler) {
    keyboardExitHandler = typeof handler === "function" ? handler : null;
  }

  function focusWithoutScroll(control) {
    if (!control || control.disabled || typeof control.focus !== "function") return false;
    try { control.focus({ preventScroll: true }); } catch (_error) {
      try { control.focus(); } catch (_focusError) { return false; }
    }
    return shadow && shadow.activeElement === control;
  }

  function cardAction(control) {
    if (!control) return null;
    if (control.dataset && control.dataset.act) return control.dataset.act;
    return control.classList && control.classList.contains("x") ? "close" : null;
  }

  function findCardAction(card, action) {
    if (!card || !action) return null;
    if (action === "close") return card.querySelector(".x");
    return [...card.querySelectorAll("button")].find((button) =>
      button.dataset && button.dataset.act === action
    ) || null;
  }

  // Rendering replaces underline/card nodes. Preserve a semantic identity—not a
  // stale element reference—so an async provider result or scroll recomputation
  // cannot strand keyboard focus on the document body.
  function keyboardFocusToken() {
    if (!shadow || !shadow.activeElement) return null;
    const active = shadow.activeElement;
    const controls = keyboardControls();
    const fallbackIndex = Math.max(0, controls.indexOf(active));
    if (active === assistantEl) return { kind:"assistant", fallbackIndex };
    if (assistantCardEl && assistantCardEl.contains(active)) {
      return {kind:"assistantCard",action:cardAction(active),fallbackIndex};
    }
    if (active.dataset && active.dataset.beanIssue) {
      const matches = [...underlineLayer.querySelectorAll("button")].filter((button) =>
        button.dataset && button.dataset.beanIssue === active.dataset.beanIssue
      );
      return { kind:"issue", id:active.dataset.beanIssue,
               occurrence:Math.max(0, matches.indexOf(active)), fallbackIndex };
    }
    if (active.dataset && active.dataset.beanParagraphGroup) {
      return { kind:"group", id:active.dataset.beanParagraphGroup, fallbackIndex };
    }
    if (cardEl && cardEl.contains(active)) {
      return { kind:"issueCard", id:cardEl.dataset.beanIssueCard,
               action:cardAction(active), fallbackIndex };
    }
    if (groupCardEl && groupCardEl.contains(active)) {
      return { kind:"groupCard", id:groupCardEl.dataset.beanGroupCard,
               action:cardAction(active), fallbackIndex };
    }
    return null;
  }

  function restoreKeyboardFocus(token) {
    if (!token || !shadow) return;
    let target = null;
    if (token.kind === "assistant" && focusWithoutScroll(assistantEl)) return;
    if (token.kind === "assistantCard") target = findCardAction(assistantCardEl,token.action);
    if (token.kind === "issue" || token.kind === "issueCard") {
      if (token.kind === "issueCard" && cardEl && cardEl.dataset.beanIssueCard === token.id) {
        target = findCardAction(cardEl, token.action);
      }
      if (!target && underlineLayer) {
        const matches = [...underlineLayer.querySelectorAll("button")].filter((button) =>
          button.dataset && button.dataset.beanIssue === token.id
        );
        target = matches[Math.min(token.occurrence || 0, Math.max(0, matches.length - 1))] || null;
      }
    } else if (token.kind === "group" || token.kind === "groupCard") {
      if (token.kind === "groupCard" && groupCardEl && groupCardEl.dataset.beanGroupCard === token.id) {
        target = findCardAction(groupCardEl, token.action);
      }
      if (!target && groupLayer) {
        target = [...groupLayer.querySelectorAll("button")].find((button) =>
          button.dataset && button.dataset.beanParagraphGroup === token.id
        ) || null;
      }
    }
    const controls = keyboardControls();
    if (target && !controls.includes(target)) target = null;
    if (!target && controls.length) {
      target = controls[Math.min(token.fallbackIndex || 0, controls.length - 1)];
    }
    if (focusWithoutScroll(target)) return;
    if (typeof keyboardExitHandler === "function") keyboardExitHandler(-1);
  }

  function clearFindings() {
    if (hoverTimer) { clearTimeout(hoverTimer); hoverTimer = null; }
    if (underlineLayer) underlineLayer.replaceChildren();
    if (cardEl) { cardEl.remove(); cardEl = null; }
    if (groupLayer) groupLayer.replaceChildren();
    if (groupCardEl) { groupCardEl.remove(); groupCardEl = null; }
  }

  function clear() {
    clearFindings();
    if (assistantCardEl) { assistantCardEl.remove(); assistantCardEl = null; }
    assistantCardState = null;
    if (paragraphReviewEl) { paragraphReviewEl.remove(); paragraphReviewEl = null; }
    if (paragraphReviewShield) { paragraphReviewShield.remove(); paragraphReviewShield = null; }
    if (paragraphBusyEl) { paragraphBusyEl.remove(); paragraphBusyEl = null; }
    if (paragraphReviewResolve) {
      const resolve = paragraphReviewResolve;
      paragraphReviewResolve = null;
      resolve(false);
    }
  }

  // A native button's accessibility action is delivered as `click`, while a
  // pointer reaches `mousedown` first. Handle both without firing twice. The
  // zero-detail click produced by keyboard/assistive technology also queues
  // focus for the card created synchronously by the activation handler.
  function wireActivationControl(element, activate) {
    let handled = false;
    const run = (keyboardLike) => {
      if (handled) return;
      handled = true;
      if (hoverTimer) {
        clearTimeout(hoverTimer);
        hoverTimer = null;
      }
      if (keyboardLike) queueKeyboardActivationFocus();
      activate();
    };
    element.addEventListener("mousedown", (event) => {
      event.preventDefault();
      run(false);
    });
    element.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      run(event.detail === 0);
    });
    element.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        event.stopPropagation();
        run(true);
      }
    });
  }

  function queueKeyboardActivationFocus() {
    keyboardActivationPending = true;
    if (keyboardActivationTimer) clearTimeout(keyboardActivationTimer);
    // Every supported transition renders synchronously. Clear an unconsumed
    // request so a refused/stale action cannot steal focus on a later mouse use.
    keyboardActivationTimer = setTimeout(() => {
      keyboardActivationPending = false;
      keyboardActivationTimer = null;
    }, 0);
  }

  function queueFocusForActivationEvent(event) {
    if (event && event.detail === 0) queueKeyboardActivationFocus();
  }

  function render(entries, selectedId, position, handlers) {
    const focusToken = keyboardFocusToken();
    try {
      // Empty async results/scroll updates clear findings while retaining a
      // still-valid expanded assistant. Explicit content invalidation calls
      // clear() and removes its captured action scope as well.
      if (!entries || !entries.length) { clearFindings(); return; }
      ensureHost();
      underlineLayer.replaceChildren();
      for (const entry of entries) {
        for (const r of entry.rects) {
          const underline = document.createElement("button");
          underline.type = "button";
          underline.className = "ul";
          underline.dataset.bean = "overlay";
          underline.dataset.beanIssue = entry.id;
          underline.setAttribute("aria-label", `Suggestion: replace ${entry.issue.original} with ${entry.issue.suggestion}`);
          Object.assign(underline.style, { left:`${r.x}px`, top:`${r.y + r.h - Math.min(6, r.h)}px`, width:`${r.w}px`, height:`${Math.min(6, r.h)}px` });
          underline.addEventListener("mouseenter", () => {
            if (hoverTimer) clearTimeout(hoverTimer);
            hoverTimer = setTimeout(() => call(handlers, "onActivate", entry.id), 180);
          });
          underline.addEventListener("mouseleave", () => { if (hoverTimer) clearTimeout(hoverTimer); });
          wireActivationControl(underline, () => call(handlers, "onActivate", entry.id));
          underlineLayer.appendChild(underline);
        }
      }
      if (cardEl) { cardEl.remove(); cardEl = null; }
      const selected = entries.find((entry) => entry.id === selectedId);
      if (selected) showCard(selected, position, handlers);
    } finally {
      restoreKeyboardFocus(focusToken);
    }
  }

  function dialogCard(label, onClose) {
    const card = document.createElement("div");
    card.className = "card";
    card.dataset.bean = "overlay";
    card.setAttribute("role", "dialog");
    card.setAttribute("aria-modal", "false");
    card.setAttribute("aria-label", label);
    card.addEventListener("mousedown", (event) => { event.preventDefault(); event.stopPropagation(); });
    card.addEventListener("keydown", (event) => {
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        onClose();
      }
    });
    return card;
  }

  function overflowMarkup() {
    return `<div class="overflow-wrap">
      <button class="more" type="button" data-act="more" aria-label="More options" aria-haspopup="menu" aria-expanded="false">•••</button>
      <div class="overflow-menu" role="menu" hidden>
        <button type="button" role="menuitem" data-act="disableField">Disable on this field</button>
        <button type="button" role="menuitem" data-act="pauseSite">Pause on this website for 1 hour</button>
        <button type="button" role="menuitem" data-act="disableSite">Disable on this website</button>
      </div>
    </div>`;
  }

  function wireButton(element, handler) {
    if (!element || element.disabled) return;
    element.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      handler(event);
    });
    // Some Shadow DOM/browser combinations do not synthesize `click` from a
    // semantic button keypress. Handle the keys explicitly and prevent the
    // default so a later synthetic click cannot apply the action twice.
    element.addEventListener("keydown", (event) => {
      if (event.key !== "Enter" && event.key !== " ") return;
      event.preventDefault();
      event.stopPropagation();
      handler(event);
    });
  }

  function wire(card, selector, handler) {
    wireButton(card.querySelector(selector), handler);
  }

  function wireOverflow(card, handlers) {
    const button = card.querySelector('[data-act="more"]');
    const menu = card.querySelector(".overflow-menu");
    if (!button || !menu) return;
    const close = (restoreFocus) => {
      menu.hidden = true;
      button.setAttribute("aria-expanded", "false");
      if (restoreFocus) button.focus();
    };
    const toggle = (event) => {
      event.preventDefault();
      event.stopPropagation();
      const opening = menu.hidden;
      menu.hidden = !opening;
      button.setAttribute("aria-expanded", String(opening));
      if (opening && event.detail === 0) menu.querySelector('[role="menuitem"]')?.focus();
    };
    button.addEventListener("click", toggle);
    button.addEventListener("keydown", (event) => {
      if (event.key !== "Enter" && event.key !== " ") return;
      toggle(event);
    });
    menu.addEventListener("keydown", (event) => {
      const items = [...menu.querySelectorAll('[role="menuitem"]')];
      const index = items.indexOf(shadow.activeElement);
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        close(true);
        return;
      }
      if (event.key === "ArrowDown" && items.length) { event.preventDefault(); items[(index + 1 + items.length) % items.length].focus(); }
      if (event.key === "ArrowUp" && items.length) { event.preventDefault(); items[(index - 1 + items.length) % items.length].focus(); }
    });
    wire(card, '[data-act="disableField"]', () => call(handlers, "onDisableField"));
    wire(card, '[data-act="pauseSite"]', (event) => call(handlers, "onPauseSite",event));
    wire(card, '[data-act="disableSite"]', () => call(handlers, "onDisableSite"));
  }

  function showCard(entry, position, handlers) {
    const issue = entry.issue;
    const card = dialogCard("Bean writing suggestion", () => call(handlers, "onClose"));
    card.dataset.beanIssueCard = entry.id;
    const posText = position ? `${position.index + 1} of ${position.total}` : "";
    card.innerHTML = `<div class="row"><span class="pill" data-part="type"></span>
      <span class="pill" data-part="position"></span><button class="x" type="button" aria-label="Close suggestion">✕</button></div>
      <div class="source"></div><div class="fix"><span class="orig"></span><span class="arrow" aria-hidden="true">→</span><span class="sugg"></span></div>
      ${issue.explanation ? '<div class="expl"></div>' : ""}
      ${Array.isArray(issue.alternatives) && issue.alternatives.length ? '<div class="alternatives"></div>' : ''}
      ${issue.type === "spelling" ? '<div class="gactions"><button class="b" type="button" data-act="learn">Add to Dictionary</button></div>' : ''}
      <div class="actions"><button class="b" type="button" data-act="ignore">Dismiss</button><span class="spacer"></span>
        ${position && position.total > 1 ? '<button class="b" type="button" data-act="next" aria-label="Next suggestion">Next</button>' : ""}
        <button class="b primary" type="button" data-act="apply">Accept</button>${overflowMarkup()}</div>`;
    card.querySelector('[data-part="type"]').textContent = cap(issue.type || "suggestion");
    card.querySelector('[data-part="position"]').textContent = posText;
    card.querySelector(".source").textContent = issue.source === "ai" ? "AI suggestion · review for accuracy" : "Local suggestion · checked on this Mac";
    card.querySelector(".orig").textContent = visibleCorrectionText(issue.original);
    card.querySelector(".sugg").textContent = visibleCorrectionText(issue.suggestion);
    if (issue.explanation) card.querySelector(".expl").textContent = issue.explanation;
    if (Array.isArray(issue.alternatives) && issue.alternatives.length) {
      const alternatives = card.querySelector(".alternatives");
      alternatives.className = "alternatives actions";
      for (const suggestion of issue.alternatives.slice(0,4)) {
        const button = document.createElement("button");
        button.type = "button"; button.className = "b";
        button.textContent = suggestion;
        button.setAttribute("aria-label",`Replace with ${suggestion}`);
        wireButton(button,(event) => {
          queueFocusForActivationEvent(event);
          call(handlers,"onApplyAlternative",entry.id,suggestion);
        });
        alternatives.appendChild(button);
      }
    }
    wire(card, ".x", () => call(handlers, "onClose"));
    const learn = card.querySelector('[data-act="learn"]');
    if (learn) {
      learn.disabled = !handlers || handlers.learnWordAvailable !== true;
      learn.title = learn.disabled ? "Open Bean to save words to your dictionary" : "Save this word in your Bean dictionary";
      wireButton(learn,(event) => call(handlers,"onLearnWord",entry.id,event));
    }
    wire(card, '[data-act="ignore"]', (event) => {
      queueFocusForActivationEvent(event);
      call(handlers, "onIgnore", entry.id);
    });
    wire(card, '[data-act="apply"]', (event) => {
      queueFocusForActivationEvent(event);
      call(handlers, "onApply", entry.id);
    });
    wire(card, '[data-act="next"]', (event) => {
      queueFocusForActivationEvent(event);
      call(handlers, "onNext");
    });
    wireOverflow(card, handlers);
    shadow.appendChild(card);
    cardEl = card;
    anchor(card, entry.rects[entry.rects.length - 1] || entry.cardAnchor);
    announce(`Suggestion: replace ${issue.original} with ${issue.suggestion}`);
    focusAfterKeyboardActivation(card, '[data-act="apply"]');
  }

  function visibleCorrectionText(text) {
    if (/^ +$/.test(text)) return `${text.length} ${text.length === 1 ? "space" : "spaces"}`;
    return text;
  }

  function focusAfterKeyboardActivation(card, selector) {
    if (!keyboardActivationPending) return;
    keyboardActivationPending = false;
    if (keyboardActivationTimer) {
      clearTimeout(keyboardActivationTimer);
      keyboardActivationTimer = null;
    }
    requestAnimationFrame(() => card.querySelector(selector)?.focus());
  }

  function anchor(card, rect) {
    const w = card.offsetWidth || 300, h = card.offsetHeight || 120, gap = 8;
    const anchorWidth = Number.isFinite(rect.w) ? rect.w : 1;
    let x = rect.x + anchorWidth / 2 - w / 2;
    x = Math.max(window.scrollX + 8, Math.min(x, window.scrollX + window.innerWidth - w - 8));
    let y = rect.y - h - gap;
    if (y < window.scrollY + 8) y = rect.y + rect.h + gap;
    y = Math.max(window.scrollY + 8, Math.min(y, window.scrollY + window.innerHeight - h - 8));
    card.style.left = `${x}px`;
    card.style.top = `${y}px`;
  }

  function cap(value) {
    const text = String(value || "");
    return text ? text.charAt(0).toUpperCase() + text.slice(1) : "";
  }

  function renderGroups(groups, selectedGroupId, handlers) {
    const focusToken = keyboardFocusToken();
    try {
      ensureHost();
      groupLayer.replaceChildren();
      if (groupCardEl) { groupCardEl.remove(); groupCardEl = null; }
      if (!groups || !groups.length) return;
      for (const group of handlers && handlers.hideIcons ? [] : groups) {
        const icon = document.createElement("button");
        icon.type = "button";
        icon.className = "pico";
        icon.dataset.bean = "overlay";
        icon.dataset.beanParagraphGroup = group.id;
        icon.setAttribute("aria-label", `${group.count} suggestions in this paragraph`);
        const image = document.createElement("img");
        image.src = officialMarkURL();
        image.alt = "";
        icon.appendChild(image);
        let x = group.anchor.x - 34;
        x = Math.max(window.scrollX + 2, x);
        Object.assign(icon.style, { left:`${x}px`, top:`${group.anchor.y}px` });
        icon.addEventListener("mouseenter", () => {
          if (hoverTimer) clearTimeout(hoverTimer);
          hoverTimer = setTimeout(() => call(handlers, "onActivateGroup", group.id), 180);
        });
        icon.addEventListener("mouseleave", () => { if (hoverTimer) clearTimeout(hoverTimer); });
        wireActivationControl(icon, () => call(handlers, "onActivateGroup", group.id));
        groupLayer.appendChild(icon);
      }
      const selected = groups.find((group) => group.id === selectedGroupId);
      if (selected) showGroupCard(selected, handlers);
    } finally {
      restoreKeyboardFocus(focusToken);
    }
  }

  function showGroupCard(group, handlers) {
    const card = dialogCard("Bean paragraph suggestions", () => call(handlers, "onCloseGroup"));
    card.dataset.bean = "overlay";
    card.dataset.beanGroupCard = group.id;
    const usesAI = group.fixMode === "ai";
    const helper = group.canFix
      ? (usesAI ? "AI checks only the paragraph you just edited." : "Fixes obvious issues locally. No text is sent.")
      : "A safe automatic fix is not available here. Review suggestions one by one.";
    const fixLabel = usesAI ? "Review AI changes" : "Fix obvious issues";
    card.innerHTML = `<div class="row"><span class="pill" data-part="count"></span>
      <button class="x" type="button" aria-label="Close paragraph suggestions">✕</button></div>
      <div class="expl" data-part="helper"></div><div class="gactions">
        <button class="b primary" type="button" data-act="fix"${group.canFix ? "" : " disabled"}></button>
        <button class="b" type="button" data-act="review">Review one by one</button>
        <button class="b" type="button" data-act="ignoreAll">Dismiss all</button>${overflowMarkup()}</div>`;
    card.querySelector('[data-part="count"]').textContent = `${group.count} suggestions in this paragraph`;
    card.querySelector('[data-part="helper"]').textContent = helper;
    card.querySelector('[data-act="fix"]').textContent = fixLabel;
    wire(card, ".x", () => call(handlers, "onCloseGroup"));
    wire(card, '[data-act="fix"]', () => call(handlers, "onFixParagraph", group.id));
    wire(card, '[data-act="review"]', (event) => {
      queueFocusForActivationEvent(event);
      call(handlers, "onReviewGroup", group.id);
    });
    wire(card, '[data-act="ignoreAll"]', () => call(handlers, "onIgnoreAllGroup", group.id));
    wireOverflow(card, handlers);
    shadow.appendChild(card);
    groupCardEl = card;
    anchor(card, { x:group.anchor.x, y:group.anchor.y, w:30, h:group.anchor.h || 30 });
    announce(`${group.count} suggestions in this paragraph`);
    focusAfterKeyboardActivation(card, '[data-act="review"]');
  }

  function assistantDescription(status, count) {
    if (status === "appPaused") return "Automatic checks paused for this app";
    if (status === "waiting") return "Checks update when you pause typing";
    if (status === "checkingLocal") return "Checking spelling on this Mac…";
    if (status === "checking") return "Checking the changed paragraph with AI…";
    if (status === "tooLong") return "This field is too long for inline checks.";
    if (count) return `${count} writing ${count === 1 ? "suggestion" : "suggestions"}`;
    if (status === "mappingLimited") return "Suggestions found · exact editing range unavailable";
    if (status === "empty") return "Ready when you start writing";
    if (status === "nativeLocal" || status === "ai") return "No spelling or basic grammar suggestions";
    return "Basic checks only · spelling connection unavailable";
  }

  function validRect(rect) {
    return !!rect && [rect.x,rect.y,rect.w,rect.h].every(Number.isFinite) && rect.w > 0 && rect.h > 0;
  }

  function intersects(a,b,gap = 0) {
    return a.x < b.x + b.w + gap && a.x + a.w + gap > b.x &&
      a.y < b.y + b.h + gap && a.y + a.h + gap > b.y;
  }

  function assistantViewport() {
    const viewport = {x:window.scrollX,y:window.scrollY,w:window.innerWidth,h:window.innerHeight};
    if (!validRect(viewport)) return null;
    const visual = window.visualViewport;
    if (!visual) return viewport;
    const visible = {x:viewport.x + visual.offsetLeft,y:viewport.y + visual.offsetTop,
      w:visual.width,h:visual.height};
    if (!validRect(visible)) return null;
    const x = Math.max(viewport.x,visible.x),y = Math.max(viewport.y,visible.y);
    const w = Math.min(viewport.x + viewport.w,visible.x + visible.w) - x;
    const h = Math.min(viewport.y + viewport.h,visible.y + visible.h) - y;
    return validRect({x,y,w,h}) ? {x,y,w,h} : null;
  }

  // Validate the entire invisible target. Never clamp a rejected outside
  // position back over the editor. Slides remain on their original edge.
  function assistantPosition(rect,viewport,exclusions = [],pointSafe = () => true) {
    if (!validRect(rect) || !validRect(viewport) || !intersects(rect,viewport) ||
        !Array.isArray(exclusions) || exclusions.some(r => !validRect(r))) return null;
    const size = ASSISTANT_TARGET_SIZE,gap = ASSISTANT_GAP,inset = 4;
    const candidates = [];
    for (const slide of [0,32,64,96]) {
      candidates.push({x:rect.x + rect.w + gap,y:rect.y + rect.h - size - slide,w:size,h:size},
        {x:rect.x + rect.w - size - slide,y:rect.y + rect.h + gap,w:size,h:size},
        {x:rect.x - size - gap,y:rect.y + rect.h - size - slide,w:size,h:size},
        {x:rect.x + rect.w - size - slide,y:rect.y - size - gap,w:size,h:size});
    }
    for (const candidate of candidates) {
      if (candidate.x < viewport.x + inset || candidate.y < viewport.y + inset ||
          candidate.x + size > viewport.x + viewport.w - inset ||
          candidate.y + size > viewport.y + viewport.h - inset || intersects(candidate,rect) ||
          exclusions.some(obstacle => intersects(candidate,obstacle,2))) continue;
      if ([1,14,27].every(dx => [1,14,27].every(dy => pointSafe(candidate.x + dx,candidate.y + dy)))) return candidate;
    }
    return null;
  }

  function composedParent(node) {
    if (!node) return null;
    if (node.assignedSlot) return node.assignedSlot;
    if (node.parentElement) return node.parentElement;
    const root = typeof node.getRootNode === "function" ? node.getRootNode() : null;
    return root && root.host || null;
  }

  function beanOwned(node) {
    for (let current = node; current; current = composedParent(current)) {
      if (current === hostEl) return true;
    }
    return false;
  }

  function sourceAncestors(source) {
    const ancestors = new Set([document.body,document.documentElement]);
    for (let current = composedParent(source); current; current = composedParent(current)) ancestors.add(current);
    return ancestors;
  }

  function sourceVisible(rect,viewport,source) {
    if (!source) return true;
    const x = Math.max(rect.x,viewport.x),y = Math.max(rect.y,viewport.y);
    const width = Math.min(rect.x + rect.w,viewport.x + viewport.w) - x;
    const height = Math.min(rect.y + rect.h,viewport.y + viewport.h) - y;
    if (width <= 0 || height <= 0) return false;
    return [0.1,0.5,0.9].some(dx => [0.1,0.5,0.9].some(dy => {
      const hit = document.elementsFromPoint(x + width * dx - window.scrollX,
        y + height * dy - window.scrollY).find(element => !beanOwned(element));
      for (let current = hit; current; current = composedParent(current)) if (current === source) return true;
      return false;
    }));
  }

  function assistantDOMPosition(rect,source) {
    const started = typeof performance !== "undefined" && typeof performance.now === "function" ? performance.now() : null;
    const overBudget = () => started !== null && performance.now() - started > 8;
    const viewport = assistantViewport();
    if (!validRect(rect) || !viewport || typeof document.elementsFromPoint !== "function" ||
        typeof document.querySelectorAll !== "function" || source && (!document.contains(source) ||
          source.ownerDocument !== document || typeof source.getRootNode === "function" && source.getRootNode() !== document)) return null;
    if (!sourceVisible(rect,viewport,source)) return null;
    const controls = document.querySelectorAll(ASSISTANT_OBSTACLES);
    const nodes = document.querySelectorAll("*");
    // Unbounded or unverifiable control geometry is not empty space.
    if (controls.length > 2048 || nodes.length > 4096) return null;
    const backgrounds = sourceAncestors(source);
    const exclusions = [];
    const measured = new Set();
    for (const control of [...controls,...nodes]) {
      if (beanOwned(control)) continue;
      if (measured.has(control)) continue;
      measured.add(control);
      const semantic = typeof control.matches === "function" && control.matches(ASSISTANT_OBSTACLES);
      if (!semantic && (backgrounds.has(control) || control === source)) continue;
      if (overBudget()) return null;
      if (typeof control.getBoundingClientRect !== "function") return null;
      const r = control.getBoundingClientRect();
      const obstacle = {x:r.left + window.scrollX,y:r.top + window.scrollY,w:r.width,h:r.height};
      if (![obstacle.x,obstacle.y,obstacle.w,obstacle.h].every(Number.isFinite)) return null;
      if (validRect(obstacle)) exclusions.push(obstacle);
    }
    return assistantPosition(rect,viewport,exclusions,(x,y) => {
      if (overBudget()) return false;
      const stack = document.elementsFromPoint(x - window.scrollX,y - window.scrollY);
      const hit = stack.find(element => !beanOwned(element));
      // A neutral ancestor/background is usable only after all its semantic
      // controls have been excluded. Unknown sibling/closed-shadow content is
      // occupied, even if the small sampling grid does not reveal its label.
      if (!hit || !backgrounds.has(hit) || hit === source || hit.shadowRoot ||
          String(hit.tagName || "").includes("-")) return false;
      for (let current = hit; current; current = composedParent(current)) {
        if (typeof current.matches === "function" && current.matches(ASSISTANT_OBSTACLES)) return false;
      }
      return true;
    });
  }

  function makeAssistantButton() {
    const button = document.createElement("button");
    button.type = "button";button.className = "assistant";
    button.dataset.bean = "overlay";button.dataset.beanAssistant = "";
    const dot = document.createElement("span");dot.className = "assistant-dot";
    dot.setAttribute("aria-hidden","true");button.appendChild(dot);
    let lastPointerCheck = 0;
    button.addEventListener("pointerenter",() => {lastPointerCheck = Date.now();refreshAssistantPlacement();});
    button.addEventListener("pointermove",() => {
      if (Date.now() - lastPointerCheck < 120) return;
      lastPointerCheck = Date.now();refreshAssistantPlacement();
    });
    button.addEventListener("mousedown",event => {refreshAssistantPlacement();event.preventDefault();});
    wireButton(button,event => {
      const current = assistantPlacementState;
      if (!current) return;
      // A page control can move between render and click. Revalidate without
      // taking a new writing snapshot or stealing focus from that control.
      if (!refreshAssistantPlacement()) return;
      queueFocusForActivationEvent(event);
      const scope = call(current.handlers,"onPrepareActions",event);
      if (scope) current.handlers.actionScope = scope;
      showAssistantCard(current.rect,current.status,current.handlers,current.count);
    });
    shadow.appendChild(button);
    return button;
  }

  function refreshAssistantPlacement() {
    const current = assistantPlacementState;
    if (!current) return false;
    const focusToken = keyboardFocusToken();
    let position = null;
    try {
      if (current.source) {
        const r = current.source.getBoundingClientRect();
        current.rect = {x:r.left + window.scrollX,y:r.top + window.scrollY,w:r.width,h:r.height};
      }
      position = assistantDOMPosition(current.rect,current.source);
    } catch (_error) {}
    if (!position) {
      if (assistantEl) assistantEl.remove();
      assistantEl = null;
      if (!validRect(current.rect) || !intersects(current.rect,assistantViewport() || {x:0,y:0,w:0,h:0})) {
        if (assistantCardEl) assistantCardEl.remove();
        assistantCardEl = null;assistantCardState = null;
      }
      if (focusToken && shadow && !shadow.activeElement) restoreKeyboardFocus(focusToken);
      return false;
    }
    ensureHost();
    if (!assistantEl) assistantEl = makeAssistantButton();
    const description = assistantDescription(current.status,current.count);
    assistantEl.setAttribute("aria-label",`Bean: ${description}. Open writing suggestions.`);
    assistantEl.title = `Bean: ${description}`;
    assistantEl.dataset.hasIssues = String(current.count > 0);
    Object.assign(assistantEl.style,{left:`${position.x}px`,top:`${position.y}px`});
    if (assistantCardState && assistantCardEl) assistantCardState.refresh(current.rect,current.status,current.count);
    return true;
  }

  // One quiet status dot per field, with a larger semantic hit target. The
  // editor remains usable when no nearby space can safely contain that target.
  function renderAssistant(rect, count, status, handlers, options = {}) {
    const focusToken = keyboardFocusToken();
    assistantPlacementState = {rect,count,status,handlers:handlers || {},source:options.source || null};
    const shown = refreshAssistantPlacement();
    if (assistantCardState && assistantCardEl) {
      const scope = assistantCardState.handlers.actionScope;
      Object.assign(assistantCardState.handlers,handlers || {});
      assistantCardState.handlers.actionScope = scope;
      assistantCardState.refresh(assistantPlacementState.rect,status,count);
    }
    restoreKeyboardFocus(focusToken);
    return shown;
  }

  function hasFieldPresentation() {
    const viewport = assistantViewport();
    if (!viewport) return false;
    const elements = [assistantEl,assistantCardEl,cardEl,groupCardEl,paragraphBusyEl,paragraphReviewEl,
      ...(underlineLayer && underlineLayer.children || [])];
    return elements.some(element => {
      if (!element || typeof element.getBoundingClientRect !== "function") return false;
      try {
        const r = element.getBoundingClientRect();
        const rect = {x:r.left + window.scrollX,y:r.top + window.scrollY,w:r.width,h:r.height};
        return validRect(rect) && intersects(rect,viewport);
      } catch (_error) {return false;}
    });
  }

  function showAssistantCard(rect, status, handlers, count = 0) {
    handlers = {...(handlers || {})};
    if (assistantCardEl) assistantCardEl.remove();
    const close = () => {
      if (assistantCardEl) assistantCardEl.remove();
      assistantCardEl = null;
      assistantCardState = null;
      call(handlers, "onClose");
    };
    const card = dialogCard("Bean writing assistant", close);
    card.innerHTML = `<div class="row"><strong></strong><button class="x" type="button" aria-label="Close writing assistant">✕</button></div>
      <div class="expl"></div>
      <div class="scope" role="group" aria-label="Writing scope">
        <button type="button" data-act="scopeDraft">Whole draft</button>
        <button type="button" data-act="scopeParagraph">Current paragraph</button>
      </div>
      <div class="actions"><button class="b" type="button" data-act="review">Review suggestions</button>
        <button class="b primary" type="button" data-act="proofread">Proofread</button></div>
      <div class="gactions" data-part="fixAllGroup"><button class="b" type="button" data-act="fixAll"></button></div>
      <div class="expl" data-part="rewriteScope">Rewrite with AI</div><div class="gactions">
        <button class="b" type="button" data-act="makeClearer">Clearer</button>
        <button class="b" type="button" data-act="makeConcise">Concise</button>
        <button class="b" type="button" data-act="makeProfessional">Professional</button>
        <button class="b" type="button" data-act="makeCasual">Friendly</button>
      </div>${overflowMarkup()}`;
    const updateScope = () => {
      const actual = handlers && handlers.actionScope || "draft";
      const scope = actual === "selection" ? "selected text" : actual === "paragraph" ? "current paragraph" : "draft";
      card.querySelector('[data-act="proofread"]').textContent = `Proofread ${scope}`;
      card.querySelector('[data-part="rewriteScope"]').textContent = `Rewrite ${scope} with AI`;
      const group = card.querySelector(".scope");
      group.hidden = actual === "selection";
      card.querySelector('[data-act="scopeDraft"]').setAttribute("aria-pressed",String(actual === "draft"));
      card.querySelector('[data-act="scopeParagraph"]').setAttribute("aria-pressed",String(actual === "paragraph"));
    };
    for (const [name,scope] of [["scopeDraft","draft"],["scopeParagraph","paragraph"]]) {
      wire(card,`[data-act="${name}"]`,(event) => {
        if (!event || event.isTrusted !== true || handlers.actionScope === "selection") return;
        const actual = call(handlers,"onPrepareActions",event,scope);
        if (actual) handlers.actionScope = actual;
        updateScope();
        if (actual !== scope) announce("This editor supports the current paragraph. Select a passage to change a different section.");
      });
    }
    const refresh = (nextRect,nextStatus,nextCount) => {
      card.querySelector("strong").textContent = assistantDescription(nextStatus,nextCount);
      card.querySelector('[data-act="review"]').hidden = nextCount === 0;
      card.querySelector('[data-part="fixAllGroup"]').hidden = !(handlers.safeFixCount > 0);
      card.querySelector('[data-act="fixAll"]').textContent = `Fix ${handlers.safeFixCount || 0} obvious ${handlers.safeFixCount === 1 ? "issue" : "issues"}`;
      updateScope();
      card.querySelector(".expl").textContent = nextStatus === "appPaused"
      ? "Automatic checking is paused in Bean Settings. Proofread and Rewrite remain available when you choose them. Resume this app from Bean’s menu or Settings."
      : ["nativeLocal","ai"].includes(nextStatus)
      ? "Spelling and basic grammar checks run on your Mac. AI checks, when enabled, cover the paragraph you last edited."
      : nextStatus === "mappingLimited" ? "Bean found possible corrections but couldn’t verify their exact range in this editor. Select the text to proofread or use Bean’s Mac keyboard shortcut."
      : nextStatus === "tooLong" ? "Select a smaller section to proofread or rewrite."
      : ["waiting","checkingLocal","checking","empty"].includes(nextStatus)
        ? "Proofread selected text or your current draft in one action. Local proofreading works without an API key."
        : "Common typo and spacing checks are available. Full spelling needs the Bean app connection. Local results don’t mean the text is error-free.";
      anchor(card,nextRect);
    };
    wire(card, ".x", close);
    wire(card,'[data-act="review"]',() => call(handlers,"onReview"));
    const all = card.querySelector('[data-act="fixAll"]');
    if (all) { all.textContent = `Fix ${handlers.safeFixCount} obvious ${handlers.safeFixCount === 1 ? "issue" : "issues"}`;
      wireButton(all,(event) => call(handlers,"onFixAll",event)); }
    for (const action of ["proofread","makeClearer","makeConcise","makeProfessional","makeCasual"]) {
      wire(card,`[data-act="${action}"]`,(event) => {
        queueFocusForActivationEvent(event);
        call(handlers,"onWritingAction",action,event);
      });
    }
    wireOverflow(card, handlers);
    shadow.appendChild(card); assistantCardEl = card;
    assistantCardState = {handlers,refresh};
    refresh(rect,status,count);
    focusAfterKeyboardActivation(card, '[data-act="proofread"]');
  }

  function clearAssistant() {
    if (assistantEl) assistantEl.remove();
    assistantEl = null;
    if (assistantCardEl) assistantCardEl.remove();
    assistantCardEl = null;
    assistantCardState = null;
    assistantPlacementState = null;
  }

  function showParagraphBusy(pageRect, message, onCancel) {
    ensureHost();
    clearParagraphBusy();
    const card = document.createElement("div");
    card.className = "card";
    card.dataset.bean = "overlay";
    card.dataset.beanParagraphBusy = "";
    card.setAttribute("role", "region");
    card.setAttribute("aria-label", "Bean paragraph progress");
    const title = document.createElement("strong");
    title.textContent = message || "Proofreading paragraph…";
    const detail = document.createElement("div");
    detail.className = "expl";
    detail.textContent = "You can keep typing. Bean will stop if this paragraph changes.";
    card.append(title, detail);
    if (typeof onCancel === "function") {
      const cancel = document.createElement("button");
      cancel.type = "button"; cancel.className = "b"; cancel.dataset.act = "cancel"; cancel.textContent = "Cancel";
      wireButton(cancel,onCancel); card.appendChild(cancel);
      card.addEventListener("keydown",(event) => {
        if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); onCancel(event); }
      });
    }
    shadow.appendChild(card);
    paragraphBusyEl = card;
    anchor(card, pageRect || { x:window.scrollX + window.innerWidth / 2, y:window.scrollY + 120, w:1, h:1 });
    announce(title.textContent);
    focusAfterKeyboardActivation(card,'[data-act="cancel"]');
  }

  function clearParagraphBusy() {
    if (paragraphBusyEl) paragraphBusyEl.remove();
    paragraphBusyEl = null;
  }

  function paragraphDiff(before, after) {
    const tokenize = (value) => String(value).split(/(\s+|[.,!?;:]+)/).filter(Boolean);
    const left = tokenize(before), right = tokenize(after);
    // Requests are capped at 2,000 characters. Keep unusually fragmented text
    // bounded too; the fallback still shows both full strings without loss.
    if (left.length > 600 || right.length > 600) return {
      before:[{ text:before, changed:before !== after }],
      after:[{ text:after, changed:before !== after }]
    };
    const lengths = Array.from({ length:left.length + 1 }, () => new Uint16Array(right.length + 1));
    for (let i = left.length - 1; i >= 0; i--) {
      for (let j = right.length - 1; j >= 0; j--) {
        lengths[i][j] = left[i] === right[j] ? lengths[i + 1][j + 1] + 1
          : Math.max(lengths[i + 1][j], lengths[i][j + 1]);
      }
    }
    const result = { before:[], after:[] };
    const append = (parts, text, changed) => {
      const last = parts[parts.length - 1];
      if (last && last.changed === changed) last.text += text;
      else parts.push({ text, changed });
    };
    let i = 0, j = 0;
    while (i < left.length || j < right.length) {
      if (i < left.length && j < right.length && left[i] === right[j]) {
        append(result.before, left[i], false); append(result.after, right[j], false); i++; j++;
      } else if (i < left.length && (j >= right.length || lengths[i + 1][j] >= lengths[i][j + 1])) {
        append(result.before, left[i++], true);
      } else append(result.after, right[j++], true);
    }
    return result;
  }

  function renderComparison(element, parts, kind) {
    element.replaceChildren();
    for (const part of parts) {
      const span = document.createElement("span");
      if (part.changed) span.className = kind === "before" ? "diff-remove" : "diff-add";
      span.textContent = part.text;
      element.appendChild(span);
    }
  }

  function reviewParagraph(pageRect, before, after, message) {
    ensureHost();
    clearParagraphBusy();
    if (paragraphReviewResolve) paragraphReviewResolve(false);
    if (paragraphReviewEl) paragraphReviewEl.remove();
    if (paragraphReviewShield) paragraphReviewShield.remove();
    paragraphReviewEl = null;
    paragraphReviewShield = null;
    return new Promise((resolve) => {
      paragraphReviewResolve = resolve;
      const finish = (approved) => {
        if (paragraphReviewEl) paragraphReviewEl.remove();
        if (paragraphReviewShield) paragraphReviewShield.remove();
        paragraphReviewEl = null;
        paragraphReviewShield = null;
        paragraphReviewResolve = null;
        resolve(approved);
      };
      const shield = document.createElement("div");
      shield.className = "modal-shield";
      shield.dataset.bean = "overlay";
      shield.setAttribute("aria-hidden", "true");
      shield.addEventListener("mousedown", (event) => {
        event.preventDefault();
        event.stopPropagation();
      });
      shield.addEventListener("click", (event) => {
        event.preventDefault();
        event.stopPropagation();
        finish(false);
      });
      const card = dialogCard("Review Bean paragraph changes", () => finish(false));
      card.classList.add("review");
      card.dataset.beanParagraphReview = "";
      card.setAttribute("aria-modal", "true");
      card.removeAttribute("aria-label");
      card.setAttribute("aria-labelledby", "bean-paragraph-review-title");
      card.innerHTML = `<div class="row"><strong id="bean-paragraph-review-title" tabindex="-1">Review paragraph changes</strong></div><div class="expl"></div>
        <div class="compare"><div><label>Original</label><pre data-part="before"></pre></div>
        <div><label>Suggested</label><pre data-part="after"></pre></div></div>
        <div class="actions"><button class="b" type="button" data-act="cancel">Cancel</button><span class="spacer"></span>
        <button class="b primary" type="button" data-act="apply">Accept changes</button></div>`;
      card.querySelector(".expl").textContent = message || "Review this result before changing the paragraph.";
      const differences = paragraphDiff(before, after);
      renderComparison(card.querySelector('[data-part="before"]'), differences.before, "before");
      renderComparison(card.querySelector('[data-part="after"]'), differences.after, "after");
      wire(card, '[data-act="cancel"]', () => finish(false));
      wire(card, '[data-act="apply"]', () => finish(true));
      card.addEventListener("keydown", (event) => {
        if (!isPlainTabEvent(event)) return;
        const controls = [...card.querySelectorAll("button:not(:disabled)")];
        if (!controls.length) return;
        const index = controls.indexOf(shadow.activeElement);
        if (event.shiftKey && (index <= 0)) {
          event.preventDefault();
          controls[controls.length - 1].focus();
        } else if (!event.shiftKey && index === controls.length - 1) {
          event.preventDefault();
          controls[0].focus();
        }
      });
      shadow.append(shield, card);
      paragraphReviewShield = shield;
      paragraphReviewEl = card;
      anchor(card, pageRect || { x:window.scrollX + window.innerWidth / 2, y:window.scrollY + 120, w:1, h:1 });
      announce("Review paragraph changes before accepting");
      requestAnimationFrame(() => card.querySelector("#bean-paragraph-review-title")?.focus());
    });
  }

  // Existing non-interactive status API. Kept outside the overlay host so an
  // input event can clear findings without erasing confirmation mid-message.
  let flashEl = null, flashTimer = null;
  function flash(pageRect, message, milliseconds) {
    if (flashTimer) { clearTimeout(flashTimer); flashTimer = null; }
    if (flashEl) { flashEl.remove(); flashEl = null; }
    if (!message) return;
    if (liveRegion) liveRegion.textContent = "";
    flashEl = document.createElement("div");
    flashEl.dataset.bean = "overlay";
    flashEl.setAttribute("role", "status");
    flashEl.setAttribute("aria-live", "polite");
    flashEl.textContent = message;
    flashEl.style.cssText = `position:absolute;z-index:2147483647;pointer-events:none;font:12px -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:${ACCENT};color:#fff;padding:5px 9px;border-radius:8px;box-shadow:0 2px 8px rgba(0,0,0,.25);white-space:nowrap;`;
    const x = Math.max(window.scrollX + 4, pageRect ? pageRect.x : window.scrollX + 8);
    const y = pageRect ? pageRect.y + (pageRect.h || 18) + 4 : window.scrollY + 8;
    Object.assign(flashEl.style, { left:`${x}px`, top:`${y}px` });
    document.body.appendChild(flashEl);
    flashTimer = setTimeout(() => {
      if (flashEl) flashEl.remove();
      flashEl = null;
      flashTimer = null;
    }, milliseconds || 1800);
  }

  // Content contract: call only after a verified replacement, and provide a
  // stale-safe handler that restores the captured range/value and dispatches input.
  function showUndo(options, handler) {
    ensureHost();
    if (undoTimer) { clearTimeout(undoTimer); undoTimer = null; }
    if (undoEl) undoEl.remove();
    const scope = options && options.scope ? String(options.scope) : "change";
    const buttonLabel = options && options.label ? String(options.label) : "Undo";
    const appliedLabel = scope === "issue" ? "Correction applied"
      : scope === "paragraph" ? "Paragraph fixed"
        : scope === "block" ? "Writing block fixed" : "Change applied";
    const toast = document.createElement("div");
    toast.className = "toast";
    toast.dataset.bean = "overlay";
    toast.dataset.beanUndoScope = scope;
    toast.setAttribute("role", "region");
    toast.setAttribute("aria-label", "Undo Bean change");
    const copy = document.createElement("strong");
    copy.textContent = appliedLabel;
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = buttonLabel;
    button.setAttribute("aria-label", buttonLabel);
    button.addEventListener("mousedown", (event) => event.preventDefault());
    wireButton(button, (event) => {
      event.preventDefault();
      event.stopPropagation();
      if (undoTimer) clearTimeout(undoTimer);
      undoTimer = null;
      toast.remove();
      if (undoEl === toast) undoEl = null;
      if (typeof handler === "function") handler();
    });
    toast.append(copy, button);
    shadow.appendChild(toast);
    undoEl = toast;
    undoTimer = setTimeout(() => {
      toast.remove();
      if (undoEl === toast) undoEl = null;
      undoTimer = null;
    }, 8000);
    announce(`${appliedLabel}. ${buttonLabel} available.`);
  }

  function clearUndo() {
    if (undoTimer) { clearTimeout(undoTimer); undoTimer = null; }
    if (undoEl) { undoEl.remove(); undoEl = null; }
  }

  // Content contract: show a persistent re-enable control after the active
  // element enters the local WeakSet; call again with false after re-enabling.
  function setFieldDisabled(disabled, options) {
    ensureHost();
    if (fieldDisabledEl) { fieldDisabledEl.remove(); fieldDisabledEl = null; }
    if (!disabled) return;
    const toast = document.createElement("div");
    toast.className = "toast";
    toast.style.bottom = "64px";
    toast.dataset.bean = "overlay";
    toast.dataset.beanFieldDisabled = "";
    toast.setAttribute("role", "region");
    toast.setAttribute("aria-label", "Bean field status");
    const copy = document.createElement("strong");
    copy.textContent = "Bean is off for this field";
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = "Re-enable";
    wireButton(button, (event) => {
      event.preventDefault();
      event.stopPropagation();
      toast.remove();
      if (fieldDisabledEl === toast) fieldDisabledEl = null;
      if (options && typeof options.onEnable === "function") options.onEnable();
    });
    toast.append(copy, button);
    shadow.appendChild(toast);
    fieldDisabledEl = toast;
    announce("Bean is off for this field. Re-enable is available.");
  }

  window.BeanOverlay = {
    render, renderGroups, clear, clearUndo, flash, reviewParagraph, showParagraphBusy,
    clearParagraphBusy, showUndo, setFieldDisabled, focusFirstControl, focusLastControl,
    hasKeyboardControls, setKeyboardExitHandler, renderAssistant, clearAssistant, refreshAssistantPlacement, hasFieldPresentation,
    _test: { cap, assistantDescription, visibleCorrectionText, paragraphDiff, officialMarkURL, wireActivationControl, wireButton,
             queueKeyboardActivationFocus, focusAfterKeyboardActivation, keyboardControls,
             isPlainTabEvent, keyboardExitDirection, keyboardFocusToken, restoreKeyboardFocus, anchor,
             assistantPosition, assistantViewport }
  };
})();
