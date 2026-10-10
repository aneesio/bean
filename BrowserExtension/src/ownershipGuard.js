// Disabled HTTP(S) sites load this focus guard instead of writing assistance.
// It never reads value/innerText/textContent, selection, or writing events.
// A five-second native lease carries an opaque token only and is challenged
// against the same top-level document and eligible focused prose surface.
(() => {
  if (!/^https?:$/.test(location.protocol) || window.top !== window) return;
  if (window.__beanOwnershipGuardLoaded) return;
  window.__beanOwnershipGuardLoaded = true;
  let blocked = false, surface = null, token = null, heartbeat = null;
  const attribute = (el,name) => String(el.getAttribute(name) || "").trim().toLowerCase();
  function excluded(el) {
    if (!el || el.nodeType !== 1 || typeof el.closest !== "function" ||
        el.disabled || el.readOnly || attribute(el,"contenteditable") === "false") return true;
    if (el.closest("button, a[href], [role='button'], [role='link'], [role='checkbox'], [role='radio'], [role='switch'], [role='tab'], [role='menuitem'], [role='option'], [inert], [aria-disabled='true'], [aria-readonly='true'], [role='searchbox'], [role='search'], .CodeMirror, .monaco-editor, .ace_editor, [role='code'], pre, code")) return true;
    if (attribute(el,"autocomplete").split(/\s+/).some((value) => ["one-time-code","current-password","new-password","webauthn"].includes(value) || /^(?:cc-|transaction-)/.test(value))) return true;
    if (["numeric","decimal"].includes(attribute(el,"inputmode"))) return true;
    const pattern = attribute(el,"pattern").replace(/\s+/g,"");
    if (/^\^?(?:\\d|\[0-9\])(?:[*+?]|\{\d+(?:,\d*)?\})?\$?$/.test(pattern)) return true;
    const semantics = ["name","id","aria-label","aria-describedby","placeholder"].map((key) => attribute(el,key)).join(" ");
    if (/(?:\botp\b|one[\s_-]*time|verification[\s_-]*(?:code|number)|security[\s_-]*code|auth(?:entication)?[\s_-]*code|pass[\s_-]*code|\bpin\b|\bcvv\b|\bcvc\b|card[\s_-]*(?:number|no\.?))/i.test(semantics)) return true;
    if (el.tagName === "INPUT" && (el.type || "text").toLowerCase() !== "text") return true;
    if (!el.offsetParent && el.tagName !== "BODY") return true;
    const rect = el.getBoundingClientRect();
    return rect.width < 8 || rect.height < 8 || location.hostname === "docs.google.com" && location.pathname.startsWith("/document");
  }
  function eligible(el) {
    if (excluded(el)) return null;
    if (el.tagName === "TEXTAREA" || el.tagName === "INPUT") return el;
    if (!el.isContentEditable) return null;
    const root = el.closest("[contenteditable]") || el;
    return excluded(root) ? null : root;
  }
  function owns() {
    return blocked && !!surface && !!token && document.visibilityState !== "hidden" && document.hasFocus() &&
      document.contains(surface) && eligible(document.activeElement) === surface;
  }
  function send(active,fieldToken = token) {
    if (!fieldToken) return;
    try { chrome.runtime.sendMessage({type:"fieldOwnership",ownership:{fieldToken,active}},() => { void chrome.runtime.lastError; }); }
    catch (_error) {}
  }
  function release() {
    if (heartbeat) clearTimeout(heartbeat);
    heartbeat = null;
    const previous = token; token = null; surface = null;
    send(false,previous);
  }
  function renew() {
    heartbeat = null;
    if (!owns()) { release(); return; }
    send(true); heartbeat = setTimeout(renew,1500);
  }
  function sync() {
    const next = blocked && document.visibilityState !== "hidden" && document.hasFocus() ? eligible(document.activeElement) : null;
    if (next !== surface) release();
    if (!next) return;
    surface = next;
    if (!token) token = `guard_${Date.now().toString(36)}_${Math.random().toString(36).slice(2)}`;
    if (heartbeat) clearTimeout(heartbeat);
    renew();
  }
  function load() {
    chrome.storage.local.get(["blockedSites"],(settings) => {
      const error = chrome.runtime.lastError;
      const raw = settings && settings.blockedSites;
      const hosts = Array.isArray(raw) ? raw.map(BeanSitePolicy.host) : null;
      blocked = !error && !!hosts && hosts.every(Boolean) && hosts.some((host) =>
        location.hostname === host || location.hostname.endsWith("." + host));
      sync();
    });
  }
  chrome.runtime.onMessage.addListener((message,sender,respond) => {
    if (!message || message.type !== "revalidateFieldOwnership") return false;
    respond({ok:sender && sender.id === chrome.runtime.id && message.fieldToken === token && owns(),fieldToken:message.fieldToken});
    return false;
  });
  chrome.storage.onChanged.addListener((changes,area) => { if (area === "local" && changes.blockedSites) load(); });
  document.addEventListener("focusin",sync,true);
  document.addEventListener("focusout",() => { release(); },true);
  document.addEventListener("visibilitychange",sync);
  window.addEventListener("focus",sync);
  window.addEventListener("blur",release);
  window.addEventListener("pagehide",release);
  load();
})();
