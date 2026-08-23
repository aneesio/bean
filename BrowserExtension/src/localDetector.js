// Bean local issue detector (deterministic, offline, no API key needed).
//
// Mirrors the Mac app's conservative local layer so the extension works out of
// the box for a demo. It finds only small, safe, localized issues and never
// rewrites whole sentences. An optional LLM provider can replace/augment this
// later (see provider notes in README); model output must still be mapped by
// exact substring and validated.
//
// PRIVACY: runs entirely in the page. It does not log, store, or send text.
(function () {
  const TYPOS = {
    teh: "the", recieve: "receive", recieved: "received", definately: "definitely",
    seperate: "separate", occured: "occurred", occurence: "occurrence", adress: "address",
    tommorow: "tomorrow", wierd: "weird", becuase: "because", thier: "their",
    accomodate: "accommodate", grammer: "grammar", enviroment: "environment",
    responsiblity: "responsibility", sucess: "success", sucessful: "successful",
    calender: "calendar", prefered: "preferred", alot: "a lot", cant: "can't",
    dont: "don't", wont: "won't", didnt: "didn't", isnt: "isn't", im: "I'm"
  };
  const MAX_ISSUES = 8;
  const MAX_LEN = 200;

  function applyCase(original, replacement) {
    if (original === original.toUpperCase() && /[A-Za-z]/.test(original)) return replacement.toUpperCase();
    if (/^[A-Z]/.test(original)) return replacement.charAt(0).toUpperCase() + replacement.slice(1);
    return replacement;
  }

  function detect(text) {
    const issues = [];
    const push = (original, suggestion, type, explanation) => {
      if (!original || original.length > MAX_LEN || !suggestion || suggestion.length > MAX_LEN) return;
      if (original === suggestion) return;
      issues.push({ original, suggestion, type, explanation });
    };

    // Repeated spaces.
    (text.match(/\S  +\S/g) || []).forEach((m) => push(m, m.replace(/ +/g, " "), "spacing", "Extra spaces."));

    // Missing space after sentence punctuation (e.g. "word,next").
    (text.match(/[a-z][,.;:!?][A-Za-z]/g) || []).forEach((m) =>
      push(m, m.charAt(0) + m.charAt(1) + " " + m.charAt(2), "punctuation", "Missing space after punctuation."));

    // Doubled words ("the the").
    (text.match(/\b(\w+)\s+\1\b/gi) || []).forEach((m) => {
      const word = m.split(/\s+/)[0];
      push(m, word, "grammar", "Repeated word.");
    });

    // Standalone lowercase "i".
    (text.match(/\bi\b/g) || []).slice(0, 3).forEach(() => push("i", "I", "capitalization", "“I” should be capitalized."));

    // Common one-word typos.
    const seen = new Set();
    (text.match(/[A-Za-z']+/g) || []).forEach((word) => {
      const lower = word.toLowerCase();
      if (TYPOS[lower] && !seen.has(lower)) {
        seen.add(lower);
        push(word, applyCase(word, TYPOS[lower]), "spelling", "Common misspelling.");
      }
    });

    return issues.slice(0, MAX_ISSUES);
  }

  // Compose overlapping deterministic fixes safely by changing one verified,
  // unique issue at a time and re-detecting against the new string. For
  // example, `works,tommorow` has a punctuation issue that shares the `t` with
  // the spelling issue; both can be fixed without trusting stale offsets.
  function fixObvious(text) {
    let result = String(text || "");
    for (let pass = 0; pass < MAX_ISSUES; pass++) {
      const candidates = detect(result)
        .map((issue) => {
          const start = result.indexOf(issue.original);
          if (start < 0 || result.indexOf(issue.original, start + 1) >= 0) return null;
          return { issue, start };
        })
        .filter(Boolean)
        .sort((left, right) => right.start - left.start);
      const candidate = candidates[0];
      if (!candidate) break;
      const { issue, start } = candidate;
      const next = result.slice(0, start) + issue.suggestion +
        result.slice(start + issue.original.length);
      if (next === result) break;
      result = next;
    }
    return result;
  }

  window.BeanDetector = { detect, fixObvious };
})();
