// Bean web overlay: subtle underlines as hit areas + an anchored correction
// card, mirroring the Mac app. Everything lives inside a Shadow DOM so the page
// styles can't leak in or out. No top-right badge — the highlight is the
// affordance.
(function () {
  const ACCENT = "#bd7f3c";
  let hostEl = null, shadow = null, underlineLayer = null, cardEl = null, hoverTimer = null;
  let groupLayer = null, groupCardEl = null;
  let paragraphReviewEl = null, paragraphReviewResolve = null;

  function ensureHost() {
    if (hostEl) return;
    hostEl = document.createElement("div");
    hostEl.id = "bean-inline-host";
    hostEl.dataset.bean = "overlay";
    hostEl.dataset.beanOverlay = "";      // test hook: [data-bean-overlay]
    hostEl.style.cssText = "position:absolute;top:0;left:0;width:0;height:0;z-index:2147483646;";
    shadow = hostEl.attachShadow({ mode: "open" });
    const style = document.createElement("style");
    style.textContent = `
      .layer { position:absolute; top:0; left:0; pointer-events:none; }
      .ul { position:absolute; pointer-events:auto; cursor:pointer;
            border-bottom:1.5px dashed ${ACCENT}; box-sizing:border-box; }
      .card { position:absolute; pointer-events:auto; width:300px;
              font:13px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
              background:rgba(250,250,250,0.98); color:#1d1d1f; border-radius:12px;
              box-shadow:0 8px 24px rgba(0,0,0,0.18); padding:12px; }
      .row { display:flex; align-items:center; gap:6px; }
      .pill { font-size:11px; color:#6b6b70; }
      .x { margin-left:auto; cursor:pointer; color:#9a9aa0; border:none; background:none; font-size:13px; }
      .fix { font-size:14px; margin:8px 0; }
      .orig { color:#8a8a8f; text-decoration:line-through; }
      .arrow { color:#9a9aa0; margin:0 6px; }
      .sugg { color:${ACCENT}; font-weight:600; }
      .expl { font-size:11px; color:#6b6b70; margin-bottom:8px; }
      .actions { display:flex; gap:6px; align-items:center; }
      .spacer { flex:1; }
      button.b { font:12px inherit; border-radius:6px; border:1px solid rgba(0,0,0,0.1);
                 background:#fff; padding:3px 9px; cursor:pointer; }
      button.primary { background:${ACCENT}; color:#fff; border-color:${ACCENT}; }
      button.b:disabled { opacity:0.45; cursor:default; }
      .pico { position:absolute; pointer-events:auto; cursor:pointer; width:18px; height:18px;
              border-radius:9px; background:${ACCENT}; color:#fff; border:1.5px solid rgba(255,255,255,0.85);
              box-shadow:0 1px 4px rgba(0,0,0,0.25); display:flex; align-items:center; justify-content:center;
              font:600 10px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; box-sizing:border-box; }
      .gactions { display:flex; gap:6px; flex-wrap:wrap; margin-top:8px; }
      .scope { display:flex; gap:10px; margin-top:10px; padding-top:8px;
               border-top:1px solid rgba(0,0,0,0.08); }
      button.scopeb { border:0; background:none; padding:0; cursor:pointer; color:#6b6b70;
                      font:11px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
      button.scopeb:hover { color:${ACCENT}; }
      .review { width:560px; }
      .compare { display:grid; grid-template-columns:1fr 1fr; gap:8px; margin:8px 0; }
      .compare label { display:block; font-size:10px; font-weight:600; color:#6b6b70; margin-bottom:4px; }
      .compare pre { box-sizing:border-box; height:150px; overflow:auto; white-space:pre-wrap;
                     margin:0; padding:8px; border-radius:7px; background:rgba(0,0,0,0.04);
                     border:1px solid rgba(0,0,0,0.08); font:12px ui-monospace,monospace; }
      @media (prefers-color-scheme: dark) {
        .card { background:rgba(40,40,42,0.98); color:#f2f2f5; }
        button.b { background:#3a3a3c; color:#f2f2f5; border-color:rgba(255,255,255,0.12); }
        .scope { border-top-color:rgba(255,255,255,0.1); }
      }
    `;
    underlineLayer = document.createElement("div");
    underlineLayer.className = "layer";
    groupLayer = document.createElement("div");
    groupLayer.className = "layer";
    shadow.appendChild(style);
    shadow.appendChild(underlineLayer);
    shadow.appendChild(groupLayer);
    document.body.appendChild(hostEl);
  }

  function clear() {
    if (hoverTimer) { clearTimeout(hoverTimer); hoverTimer = null; }
    if (underlineLayer) underlineLayer.innerHTML = "";
    if (cardEl) { cardEl.remove(); cardEl = null; }
    if (groupLayer) groupLayer.innerHTML = "";
    if (groupCardEl) { groupCardEl.remove(); groupCardEl = null; }
    if (paragraphReviewEl) { paragraphReviewEl.remove(); paragraphReviewEl = null; }
    if (paragraphReviewResolve) {
      const resolve = paragraphReviewResolve; paragraphReviewResolve = null; resolve(false);
    }
  }

  function render(entries, selectedId, position, handlers) {
    if (!entries.length) { clear(); return; }
    ensureHost();
    if (underlineLayer) underlineLayer.innerHTML = "";

    for (const entry of entries) {
      for (const r of entry.rects) {
        const ul = document.createElement("div");
        ul.className = "ul";
        ul.dataset.beanIssue = entry.id;  // test hook: [data-bean-issue]
        ul.style.left = r.x + "px";
        ul.style.top = r.y + "px";
        ul.style.width = r.w + "px";
        ul.style.height = r.h + "px";
        ul.addEventListener("mouseenter", () => {
          if (hoverTimer) clearTimeout(hoverTimer);
          hoverTimer = setTimeout(() => handlers.onActivate(entry.id), 180);
        });
        ul.addEventListener("mouseleave", () => { if (hoverTimer) clearTimeout(hoverTimer); });
        ul.addEventListener("mousedown", (e) => { e.preventDefault(); handlers.onActivate(entry.id); });
        underlineLayer.appendChild(ul);
      }
    }

    if (cardEl) { cardEl.remove(); cardEl = null; }
    const sel = entries.find((e) => e.id === selectedId);
    if (sel) showCard(sel, position, handlers);
  }

  function showCard(entry, position, handlers) {
    const issue = entry.issue;
    const card = document.createElement("div");
    card.className = "card";
    const posText = position ? `${position.index + 1} of ${position.total}` : "";
    card.innerHTML = `
      <div class="row">
        <span class="pill">${cap(issue.type || "suggestion")}</span>
        <span class="pill">${posText}</span>
        <button class="x" title="Close">✕</button>
      </div>
      <div class="fix"><span class="orig"></span><span class="arrow">→</span><span class="sugg"></span></div>
      ${issue.explanation ? `<div class="expl"></div>` : ""}
      <div class="actions">
        <button class="b" data-act="ignore">Ignore</button>
        <span class="spacer"></span>
        ${position && position.total > 1 ? `<button class="b" data-act="next" title="Next">→</button>` : ""}
        <button class="b primary" data-act="apply">Apply</button>
      </div>
      <div class="scope">
        <button class="scopeb" data-act="disableField">Disable on this field</button>
        <button class="scopeb" data-act="disableSite">Disable on this website</button>
      </div>`;
    card.querySelector(".orig").textContent = issue.original;
    card.querySelector(".sugg").textContent = issue.suggestion;
    if (issue.explanation) card.querySelector(".expl").textContent = issue.explanation;

    // CRITICAL: prevent mousedown on the card from blurring the editable field.
    // Without this, clicking a button moves focus to it → the field's focusout
    // tears the overlay down before the button's click handler can run.
    card.addEventListener("mousedown", (e) => { e.preventDefault(); e.stopPropagation(); });

    const wire = (sel, fn) => {
      const el = card.querySelector(sel);
      if (el) el.addEventListener("click", (e) => { e.preventDefault(); e.stopPropagation(); fn(); });
    };
    wire(".x", () => handlers.onClose());
    wire('[data-act="ignore"]', () => handlers.onIgnore(entry.id));
    wire('[data-act="apply"]', () => handlers.onApply(entry.id));
    wire('[data-act="next"]', () => handlers.onNext());
    wire('[data-act="disableField"]', () => handlers.onDisableField());
    wire('[data-act="disableSite"]', () => handlers.onDisableSite());

    shadow.appendChild(card);
    cardEl = card;
    anchor(card, entry.rects[0]);
  }

  function anchor(card, rect) {
    const w = card.offsetWidth || 300, h = card.offsetHeight || 120, gap = 8;
    let x = rect.x + rect.w / 2 - w / 2;
    x = Math.max(window.scrollX + 8, Math.min(x, window.scrollX + window.innerWidth - w - 8));
    let y = rect.y - h - gap; // above
    if (y < window.scrollY + 8) y = rect.y + rect.h + gap; // below if no room
    card.style.left = x + "px";
    card.style.top = y + "px";
  }

  function cap(s) { return s.charAt(0).toUpperCase() + s.slice(1); }

  // --- Paragraph-level control: a tiny icon per multi-issue paragraph, and a
  // compact card with Apply all / Review one by one / Ignore all. Same focus
  // safety as the correction card (mousedown preventDefault) and same Shadow DOM.
  function renderGroups(groups, selectedGroupId, handlers) {
    ensureHost();
    if (groupLayer) groupLayer.innerHTML = "";
    if (groupCardEl) { groupCardEl.remove(); groupCardEl = null; }
    if (!groups || !groups.length) return;

    for (const g of groups) {
      const icon = document.createElement("div");
      icon.className = "pico";
      icon.dataset.bean = "overlay";
      icon.dataset.beanParagraphGroup = g.id; // test hook: [data-bean-paragraph-group]
      icon.textContent = String(g.count > 9 ? "9+" : g.count);
      icon.title = `${g.count} suggestions in this paragraph`;
      let x = g.anchor.x - 22, y = g.anchor.y;
      x = Math.max(window.scrollX + 2, x);
      icon.style.left = x + "px";
      icon.style.top = y + "px";
      icon.addEventListener("mouseenter", () => {
        if (hoverTimer) clearTimeout(hoverTimer);
        hoverTimer = setTimeout(() => handlers.onActivateGroup(g.id), 180);
      });
      icon.addEventListener("mouseleave", () => { if (hoverTimer) clearTimeout(hoverTimer); });
      icon.addEventListener("mousedown", (e) => { e.preventDefault(); e.stopPropagation(); handlers.onActivateGroup(g.id); });
      groupLayer.appendChild(icon);
    }

    const sel = groups.find((g) => g.id === selectedGroupId);
    if (sel) showGroupCard(sel, handlers);
  }

  function showGroupCard(group, handlers) {
    const card = document.createElement("div");
    card.className = "card";
    card.dataset.bean = "overlay";
    const helper = group.canFix
      ? `<div class="expl">Fix Paragraph proofreads the whole paragraph in one pass.</div>`
      : `<div class="expl">Fix Paragraph is not available here. Review suggestions one by one.</div>`;
    card.innerHTML = `
      <div class="row">
        <span class="pill">${group.count} suggestions in this paragraph</span>
        <button class="x" title="Close">✕</button>
      </div>
      ${helper}
      <div class="gactions">
        <button class="b primary" data-act="fix"${group.canFix ? "" : " disabled"}>Fix Paragraph</button>
        <button class="b" data-act="review">Review one by one</button>
        <button class="b" data-act="ignoreAll">Ignore all</button>
      </div>
      <div class="scope">
        <button class="scopeb" data-act="disableField">Disable on this field</button>
        <button class="scopeb" data-act="disableSite">Disable on this website</button>
      </div>`;

    // Same blur-safety as the correction card.
    card.addEventListener("mousedown", (e) => { e.preventDefault(); e.stopPropagation(); });
    const wire = (sel, fn) => {
      const el = card.querySelector(sel);
      if (el && !el.disabled) el.addEventListener("click", (e) => { e.preventDefault(); e.stopPropagation(); fn(); });
    };
    wire(".x", () => handlers.onCloseGroup());
    wire('[data-act="fix"]', () => handlers.onFixParagraph(group.id));
    wire('[data-act="review"]', () => handlers.onReviewGroup(group.id));
    wire('[data-act="ignoreAll"]', () => handlers.onIgnoreAllGroup(group.id));
    wire('[data-act="disableField"]', () => handlers.onDisableField());
    wire('[data-act="disableSite"]', () => handlers.onDisableSite());

    shadow.appendChild(card);
    groupCardEl = card;
    anchor(card, { x: group.anchor.x, y: group.anchor.y, w: 18, h: group.anchor.h || 18 });
  }

  // Review-required whole-paragraph output is never applied automatically.
  // Show a before/after card and resolve only after an explicit user choice.
  function reviewParagraph(pageRect, before, after, message) {
    ensureHost();
    if (paragraphReviewResolve) paragraphReviewResolve(false);
    if (paragraphReviewEl) paragraphReviewEl.remove();
    return new Promise((resolve) => {
      paragraphReviewResolve = resolve;
      const card = document.createElement("div");
      card.className = "card review";
      card.dataset.beanParagraphReview = "";
      card.innerHTML = `
        <div class="row"><strong>Review unusual result</strong><span class="spacer"></span></div>
        <div class="expl"></div>
        <div class="compare">
          <div><label>BEFORE</label><pre data-part="before"></pre></div>
          <div><label>AFTER</label><pre data-part="after"></pre></div>
        </div>
        <div class="actions"><button class="b" data-act="cancel">Cancel</button>
          <span class="spacer"></span><button class="b primary" data-act="apply">Apply reviewed result</button></div>`;
      card.querySelector(".expl").textContent = message || "Review this result before changing the paragraph.";
      card.querySelector('[data-part="before"]').textContent = before;
      card.querySelector('[data-part="after"]').textContent = after;
      card.addEventListener("mousedown", (e) => { e.preventDefault(); e.stopPropagation(); });
      const finish = (approved) => {
        if (paragraphReviewEl) paragraphReviewEl.remove();
        paragraphReviewEl = null; paragraphReviewResolve = null; resolve(approved);
      };
      card.querySelector('[data-act="cancel"]').addEventListener("click", (e) => {
        e.preventDefault(); e.stopPropagation(); finish(false);
      });
      card.querySelector('[data-act="apply"]').addEventListener("click", (e) => {
        e.preventDefault(); e.stopPropagation(); finish(true);
      });
      shadow.appendChild(card);
      paragraphReviewEl = card;
      anchor(card, pageRect || { x: window.scrollX + window.innerWidth / 2, y: window.scrollY + 120, w: 1, h: 1 });
    });
  }

  // A small, self-removing status toast (e.g. "Paragraph fixed"). It lives in its
  // OWN element on the page — not the cleared overlay host — so the field's input
  // event (which tears the overlay down) doesn't wipe it mid-message.
  let flashEl = null, flashTimer = null;
  function flash(pageRect, msg, ms) {
    if (flashTimer) { clearTimeout(flashTimer); flashTimer = null; }
    if (flashEl) { flashEl.remove(); flashEl = null; }
    if (!msg) return;
    flashEl = document.createElement("div");
    flashEl.dataset.bean = "overlay";
    flashEl.textContent = msg;
    flashEl.style.cssText =
      "position:absolute;z-index:2147483647;pointer-events:none;" +
      "font:12px -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;" +
      `background:${ACCENT};color:#fff;padding:3px 8px;border-radius:7px;` +
      "box-shadow:0 2px 8px rgba(0,0,0,0.25);white-space:nowrap;opacity:0;transition:opacity .12s;";
    const x = Math.max(window.scrollX + 4, (pageRect ? pageRect.x : window.scrollX + 8));
    const y = (pageRect ? pageRect.y + (pageRect.h || 18) + 4 : window.scrollY + 8);
    flashEl.style.left = x + "px";
    flashEl.style.top = y + "px";
    document.body.appendChild(flashEl);
    requestAnimationFrame(() => { if (flashEl) flashEl.style.opacity = "1"; });
    flashTimer = setTimeout(() => {
      if (flashEl) { flashEl.style.opacity = "0"; const e = flashEl; setTimeout(() => e.remove(), 160); flashEl = null; }
      flashTimer = null;
    }, ms || 1500);
  }

  window.BeanOverlay = { render, renderGroups, clear, flash, reviewParagraph };
})();
