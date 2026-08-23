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
  let keyboardExitHandler = null;

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
              --bean-muted:#66615c; --bean-surface:rgba(255,253,250,.98); --bean-line:#d8d1c9; }
      * { box-sizing:border-box; }
      .layer { position:absolute; top:0; left:0; pointer-events:none; }
      button { font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
      button:focus-visible { outline:3px solid var(--bean-accent); outline-offset:2px; }
      .ul { position:absolute; pointer-events:auto; cursor:pointer; margin:0; padding:0;
            border:0; border-bottom:2px dashed var(--bean-accent); background:transparent; box-sizing:border-box; }
      .ul:hover,.ul:focus-visible { background:color-mix(in srgb,var(--bean-accent) 10%,transparent); }
      .card { position:absolute; pointer-events:auto; width:min(300px,calc(100vw - 16px));
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
      .spacer { flex:1; }
      button.b { min-height:32px; border-radius:8px; border:1px solid var(--bean-line);
                 background:var(--bean-surface); color:var(--bean-ink); padding:5px 10px; cursor:pointer; font-size:12px; }
      button.b:hover { border-color:var(--bean-accent); }
      button.primary { background:var(--bean-accent); color:#fff; border-color:var(--bean-accent); font-weight:650; }
      button.b:disabled { opacity:.45; cursor:default; }
      .pico { position:absolute; pointer-events:auto; cursor:pointer; width:30px; height:30px; padding:2px;
              border-radius:9px; background:var(--bean-surface); border:1px solid var(--bean-line);
              box-shadow:0 2px 8px rgba(0,0,0,.2); box-sizing:border-box; }
      .pico img { display:block; width:24px; height:24px; border-radius:7px; }
      .pico:hover { border-color:var(--bean-accent); transform:translateY(-1px); }
      .gactions { display:flex; gap:7px; flex-wrap:wrap; margin-top:8px; }
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
                     border:1px solid var(--bean-line); font:12px ui-monospace,monospace; }
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
                --bean-surface:rgba(41,38,34,.98); --bean-line:#59514a; }
        button.primary { color:#21160d; }
      }
      @media (prefers-reduced-motion:reduce) { .pico:hover { transform:none; } * { transition:none !important; } }
      @media (forced-colors:active) { .card,.pico,.toast,button.b,.overflow-menu { border:1px solid CanvasText; }
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
    if (handlers && typeof handlers[name] === "function") handlers[name](...args);
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

  function clear() {
    if (hoverTimer) { clearTimeout(hoverTimer); hoverTimer = null; }
    if (underlineLayer) underlineLayer.replaceChildren();
    if (cardEl) { cardEl.remove(); cardEl = null; }
    if (groupLayer) groupLayer.replaceChildren();
    if (groupCardEl) { groupCardEl.remove(); groupCardEl = null; }
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
      if (!entries || !entries.length) { clear(); return; }
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
          Object.assign(underline.style, { left:`${r.x}px`, top:`${r.y}px`, width:`${r.w}px`, height:`${r.h}px` });
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
    wire(card, '[data-act="disableSite"]', () => call(handlers, "onDisableSite"));
  }

  function showCard(entry, position, handlers) {
    const issue = entry.issue;
    const card = dialogCard("Bean writing suggestion", () => call(handlers, "onClose"));
    card.dataset.beanIssueCard = entry.id;
    const posText = position ? `${position.index + 1} of ${position.total}` : "";
    card.innerHTML = `<div class="row"><span class="pill" data-part="type"></span>
      <span class="pill" data-part="position"></span><button class="x" type="button" aria-label="Close suggestion">✕</button></div>
      <div class="fix"><span class="orig"></span><span class="arrow" aria-hidden="true">→</span><span class="sugg"></span></div>
      ${issue.explanation ? '<div class="expl"></div>' : ""}
      <div class="actions"><button class="b" type="button" data-act="ignore">Ignore</button><span class="spacer"></span>
        ${position && position.total > 1 ? '<button class="b" type="button" data-act="next" aria-label="Next suggestion">Next</button>' : ""}
        <button class="b primary" type="button" data-act="apply">Apply</button>${overflowMarkup()}</div>`;
    card.querySelector('[data-part="type"]').textContent = cap(issue.type || "suggestion");
    card.querySelector('[data-part="position"]').textContent = posText;
    card.querySelector(".orig").textContent = issue.original;
    card.querySelector(".sugg").textContent = issue.suggestion;
    if (issue.explanation) card.querySelector(".expl").textContent = issue.explanation;
    wire(card, ".x", () => call(handlers, "onClose"));
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
    anchor(card, entry.rects[0]);
    announce(`Suggestion: replace ${issue.original} with ${issue.suggestion}`);
    focusAfterKeyboardActivation(card, '[data-act="apply"]');
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
    let x = rect.x + rect.w / 2 - w / 2;
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
      for (const group of groups) {
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
    const fixLabel = usesAI ? "AI Proofread Paragraph" : "Fix Obvious Issues";
    card.innerHTML = `<div class="row"><span class="pill" data-part="count"></span>
      <button class="x" type="button" aria-label="Close paragraph suggestions">✕</button></div>
      <div class="expl" data-part="helper"></div><div class="gactions">
        <button class="b primary" type="button" data-act="fix"${group.canFix ? "" : " disabled"}></button>
        <button class="b" type="button" data-act="review">Review one by one</button>
        <button class="b" type="button" data-act="ignoreAll">Ignore all</button>${overflowMarkup()}</div>`;
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
    focusAfterKeyboardActivation(card, group.canFix ? '[data-act="fix"]' : '[data-act="review"]');
  }

  function showParagraphBusy(pageRect, message) {
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
    shadow.appendChild(card);
    paragraphBusyEl = card;
    anchor(card, pageRect || { x:window.scrollX + window.innerWidth / 2, y:window.scrollY + 120, w:1, h:1 });
    announce(title.textContent);
  }

  function clearParagraphBusy() {
    if (paragraphBusyEl) paragraphBusyEl.remove();
    paragraphBusyEl = null;
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
      const card = dialogCard("Review unusual Bean result", () => finish(false));
      card.classList.add("review");
      card.dataset.beanParagraphReview = "";
      card.setAttribute("aria-modal", "true");
      card.removeAttribute("aria-label");
      card.setAttribute("aria-labelledby", "bean-paragraph-review-title");
      card.innerHTML = `<div class="row"><strong id="bean-paragraph-review-title" tabindex="-1">Review unusual result</strong></div><div class="expl"></div>
        <div class="compare"><div><label>BEFORE</label><pre data-part="before"></pre></div>
        <div><label>AFTER</label><pre data-part="after"></pre></div></div>
        <div class="actions"><button class="b" type="button" data-act="cancel">Cancel</button><span class="spacer"></span>
        <button class="b primary" type="button" data-act="apply">Apply reviewed result</button></div>`;
      card.querySelector(".expl").textContent = message || "Review this result before changing the paragraph.";
      card.querySelector('[data-part="before"]').textContent = before;
      card.querySelector('[data-part="after"]').textContent = after;
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
      announce("Review unusual Bean result before applying");
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
    hasKeyboardControls, setKeyboardExitHandler,
    _test: { cap, officialMarkURL, wireActivationControl, wireButton,
             queueKeyboardActivationFocus, focusAfterKeyboardActivation, keyboardControls,
             isPlainTabEvent, keyboardExitDirection, keyboardFocusToken, restoreKeyboardFocus }
  };
})();
