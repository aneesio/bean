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

  // These tokens are writing data, not prose. Punctuation and spelling inside
  // a URL, email address, domain, or file name must never become a correction.
  function protectedRanges(text) {
    const ranges = [];
    const pattern = /(?:https?:\/\/|www\.)[^\s<>]+|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}|\b[A-Z0-9_-]+(?:\.[A-Z0-9_-]+)+\b/gi;
    for (const match of text.matchAll(pattern)) {
      ranges.push({ start: match.index, end: match.index + match[0].length });
    }
    return ranges;
  }

  function detect(text) {
    if (typeof text !== "string" || !text) return [];
    const issues = [];
    const protectedText = protectedRanges(text);
    const push = (start, original, suggestion, type, explanation) => {
      const end = start + original.length;
      if (!original || original.length > MAX_LEN || !suggestion || suggestion.length > MAX_LEN) return;
      if (original === suggestion || protectedText.some((range) => start < range.end && end > range.start)) return;
      // Exact offsets come only from the local scanner. Providers retain the
      // unique-substring rule; a repeated local typo can safely be fixed one at a time.
      issues.push({ original, suggestion, type, explanation, source: "local", start, end });
    };

    for (const match of text.matchAll(/(?<=\S) {2,}(?=\S)/g)) {
      push(match.index, match[0], match[0].replace(/ +/g, " "), "spacing", "Use one space between words.");
    }
    // Periods are intentionally excluded: domains, abbreviations, and version
    // numbers are indistinguishable from missing sentence spaces locally.
    for (const match of text.matchAll(/[a-z][,;:!?][A-Za-z]/g)) {
      push(match.index, match[0], match[0][0] + match[0][1] + " " + match[0][2],
           "punctuation", "Add a space after punctuation.");
    }
    // 'had had' and 'that that' are valid English. Limit this rule to the small
    // set of function words whose accidental repetition is unambiguous in prose.
    for (const match of text.matchAll(/\b(the|a|an|and|to|of|in|on|with|for|at|from|by|or)([ \t]+)\1\b/gi)) {
      push(match.index, match[0], match[1], "grammar", "Remove the repeated word.");
    }
    for (const match of text.matchAll(/\bi\b/g)) {
      push(match.index, match[0], "I", "capitalization", "Capitalize the pronoun “I”.");
    }
    for (const match of text.matchAll(/[A-Za-z']+/g)) {
      const word = match[0], replacement = TYPOS[word.toLowerCase()];
      if (replacement) push(match.index, word, applyCase(word, replacement), "spelling", "Correct this common misspelling.");
    }
    // Present a useful reading order and favor spelling over a longer finding
    // when ranges overlap. A new pass finds remaining spacing after an accept.
    issues.sort((left, right) => left.start - right.start ||
      (Number(right.type === "spelling") - Number(left.type === "spelling")) || left.end - right.end);
    const selected = [];
    for (const issue of issues) {
      if (selected.some((other) => issue.start < other.end && issue.end > other.start)) continue;
      selected.push(issue);
      if (selected.length >= MAX_ISSUES) break;
    }
    return selected;
  }

  function fixObvious(text) {
    let result = String(text || "");
    // Re-scan each time so overlapping findings and repeated words never rely
    // on stale offsets. Bound the work independently of the visible issue cap.
    for (let pass = 0; pass < 64; pass++) {
      const candidate = detect(result)[0];
      if (!candidate) break;
      const { start, end, original, suggestion } = candidate;
      if (result.slice(start, end) !== original) break;
      result = result.slice(0, start) + suggestion + result.slice(end);
    }
    return result;
  }

  window.BeanDetector = { detect, fixObvious };
})();
