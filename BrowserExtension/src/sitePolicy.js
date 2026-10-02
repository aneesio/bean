// Shared host-only website pause policy. Drafts and dictionary words never
// enter extension storage. Invalid policy fails closed at every text boundary.
(function (root) {
  const HOUR = 60 * 60 * 1000, MAX_SITES = 200;
  function host(value) {
    if (typeof value !== "string") return null;
    let normalized = value.trim().toLowerCase().replace(/\.$/, "");
    if (normalized.startsWith(".")) normalized = normalized.slice(1);
    if (!normalized || normalized.length > 253 || /[\s/@*]/.test(normalized)) return null;
    if (normalized.startsWith("[") && normalized.endsWith("]")) return /^\[[0-9a-f:.]+\]$/.test(normalized) ? normalized : null;
    return normalized.split(".").every((label) => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label)) ? normalized : null;
  }
  function normalize(value, now = Date.now()) {
    if (value === undefined) return {};
    if (!value || typeof value !== "object" || Array.isArray(value)) return null;
    const entries = Object.entries(value);
    if (entries.length > MAX_SITES) return null;
    const result = {};
    for (const [raw, expiry] of entries) {
      const key = host(raw);
      if (!key || !Number.isFinite(expiry) || expiry <= 0) return null;
      if (expiry > now) result[key] = expiry;
    }
    return result;
  }
  // Temporary pauses target this exact host. Permanent block rules continue
  // to include subdomains, but pausing one editor must not hide unrelated sites.
  function until(value, currentHost, now = Date.now()) {
    const normalized = normalize(value, now), key = host(currentHost);
    return normalized && key && Object.prototype.hasOwnProperty.call(normalized,key) ? normalized[key] : null;
  }
  function mutate(value, currentHost, operation, now = Date.now()) {
    const normalized = normalize(value, now), key = host(currentHost);
    if (!normalized || !key || !["pause", "resume"].includes(operation)) return null;
    if (operation === "resume") delete normalized[key];
    else {
      if (!Object.prototype.hasOwnProperty.call(normalized,key) && Object.keys(normalized).length >= MAX_SITES) return null;
      normalized[key] = now + HOUR;
    }
    return normalized;
  }
  const policy = { HOUR, MAX_SITES, host, normalize, until, mutate };
  root.BeanSitePolicy = policy;
  if (typeof module === "object" && module.exports) module.exports = policy;
})(typeof globalThis !== "undefined" ? globalThis : this);
