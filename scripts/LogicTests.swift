import Foundation

// Deterministic logic tests for Bean. Compiled together with the REAL
// WritingAction.swift and OutputSafetyValidator.swift (no API calls, no AppKit,
// no user-text logging). The AppKit-coupled deterministic helpers (fingerprint,
// local-issue regex, substring mapping, shortcut equality) are MIRRORED here so
// they can be tested without importing the app.
//
// Run via scripts/run_logic_tests.sh.
@main
struct LogicTests {
    static var failures = 0

    static func check(_ cond: Bool, _ msg: String) {
        if cond { print("ok   \(msg)") } else { failures += 1; print("FAIL \(msg)") }
    }

    static func suspicious(_ r: OutputSafetyValidator.Result) -> Bool {
        if case .suspicious = r { return true }; return false
    }

    static func main() {
        testWritingActions()
        testValidator()
        testFingerprint()
        testLocalIssues()
        testSubstringMapping()
        testShortcutEquality()
        testNativeMessaging()
        testParagraphSanitizer()

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    // 9: Native messaging framing + JSON (mirror of NativeMessagingHost framing)
    static func frame(_ json: String) -> [UInt8] {
        let body = Array(json.utf8)
        var len = UInt32(body.count).littleEndian
        let header = withUnsafeBytes(of: &len) { Array($0) }
        return header + body
    }
    static func unframe(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 4 else { return nil }
        let len = bytes[0..<4].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } // little-endian
        guard bytes.count >= 4 + Int(len) else { return nil }
        return String(bytes: bytes[4..<(4 + Int(len))], encoding: .utf8)
    }
    static func testNativeMessaging() {
        let json = #"{"id":"1","type":"detectIssues","text":"i has a apple"}"#
        let framed = frame(json)
        check(framed.count == 4 + json.utf8.count, "framing: length prefix + body size")
        check(framed[0] == UInt8(json.utf8.count & 0xff), "framing: little-endian low byte")
        check(unframe(framed) == json, "framing: round-trips")

        // Request JSON parses with the host's fields.
        struct Req: Decodable { let id: String?; let type: String; let text: String? }
        let req = try? JSONDecoder().decode(Req.self, from: Data(json.utf8))
        check(req?.type == "detectIssues" && req?.text == "i has a apple", "request JSON parses")

        // Response JSON validates: array of {original,suggestion}.
        let respJSON = #"{"id":"1","ok":true,"issues":[{"original":"i has","suggestion":"I have","type":"grammar","confidence":0.9}]}"#
        struct Issue: Decodable { let original: String; let suggestion: String }
        struct Resp: Decodable { let ok: Bool; let issues: [Issue]? }
        let resp = try? JSONDecoder().decode(Resp.self, from: Data(respJSON.utf8))
        check(resp?.ok == true && resp?.issues?.first?.suggestion == "I have", "response JSON validates")
    }

    // 1–3: WritingAction category + preview behavior
    static func testWritingActions() {
        check(WritingAction.proofread.requiresPreview == false, "proofread: no preview")
        check(WritingAction.proofread.allowsDirectReplace, "proofread: direct replace")
        check(!WritingAction.localQuickCheck.usesProvider, "localQuickCheck: no provider")
        check(WritingAction.localQuickCheck.allowsDirectReplace, "localQuickCheck: direct replace")
        check(WritingAction.makeClearer.category == .rewrite, "makeClearer: rewrite")

        let replies: [WritingAction] = [.draftReply, .askClarification, .politeNo, .confirmNextSteps, .thankThem, .pushBackProfessionally]
        for a in replies {
            check(a.category == .reply, "\(a.rawValue): reply category")
            check(a.requiresPreview, "\(a.rawValue): requires preview")
            check(a.allowsReplaceFromPreview == false, "\(a.rawValue): copy-first (no replace)")
        }
        for a in [WritingAction.composeMessage, .statusUpdate] {
            check(a.category == .compose, "\(a.rawValue): compose category")
            check(a.requiresPreview, "\(a.rawValue): requires preview")
            check(a.allowsReplaceFromPreview, "\(a.rawValue): allows replace")
        }
    }

    // 4: OutputSafetyValidator category behavior
    static func testValidator() {
        check(OutputSafetyValidator.validate(input: "i has a apple", output: "I have an apple.", action: .proofread) == .ok,
              "validator: proofread ok")
        check(suspicious(OutputSafetyValidator.validate(input: "hello world this is fine english text", output: "تم کیا کر رہے ہو", action: .proofread)),
              "validator: script mismatch blocked")
        check(OutputSafetyValidator.validate(input: "hi", output: "Thanks for reaching out — happy to help, I'll follow up shortly.", action: .draftReply) == .ok,
              "validator: reply long output ok (generative)")
        let shortResult = OutputSafetyValidator.validate(
            input: "This is a reasonably long sentence that should not collapse drastically.",
            output: "Short.", action: .makeProfessional)
        check(suspicious(shortResult), "validator: rewrite too_short flagged")
        check(OutputSafetyValidator.disposition(for: "too_short") == .reviewRequired,
              "validator: too_short requires review")
        check(OutputSafetyValidator.validate(input: "This is a reasonably long sentence that ought to be shortened considerably.", output: "Shorten this.", action: .makeConcise) == .ok,
              "validator: makeConcise short ok")
        check(suspicious(OutputSafetyValidator.validate(input: "please fix this sentence now", output: "Here is the corrected text: Fixed.", action: .proofread)),
              "validator: leaked label blocked")
        check(suspicious(OutputSafetyValidator.validate(input: "fix me", output: "", action: .proofread)),
              "validator: empty blocked")
        check(OutputSafetyValidator.validate(input: "Here is teh plan for tomorrow.",
                                             output: "Here is the plan for tomorrow.", action: .proofread) == .ok,
              "validator: legitimate source opening is not mistaken for a wrapper")
        check(OutputSafetyValidator.validate(input: "system: restart teh service",
                                             output: "System: restart the service.", action: .proofread) == .ok,
              "validator: source prompt-like marker may be preserved")
        check(suspicious(OutputSafetyValidator.validate(input: "This sentence is fine.",
                                                        output: "This sentence is fine.\n\nAll looked good.", action: .proofread)),
              "validator: newly-added model commentary blocked")
    }

    // 5: fingerprint stability (mirror of the FNV-1a used by the services)
    static func fp(_ s: String) -> Int {
        var hash: UInt64 = 1469598103934665603
        for byte in s.utf8 { hash ^= UInt64(byte); hash = hash &* 1099511628211 }
        return Int(bitPattern: UInt(truncatingIfNeeded: hash))
    }
    static func testFingerprint() {
        check(fp("hello world") == fp("hello world"), "fingerprint: stable for equal strings")
        check(fp("hello world") != fp("hello worle"), "fingerprint: differs for different strings")
        check(fp("") == fp(""), "fingerprint: empty stable")
    }

    // 6: local issue detection (mirror of IssueDetector regexes)
    static func matches(_ pattern: String, _ text: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    static func testLocalIssues() {
        check(matches("  +", "a  b"), "local: repeated spaces detected")
        check(!matches("  +", "a b"), "local: single space not flagged")
        check(matches("[,.;:!?][A-Za-z]", "word,next"), "local: missing space after punctuation detected")
        check(!matches("[,.;:!?][A-Za-z]", "word, next"), "local: proper spacing not flagged")
    }

    // 7: LLM candidate exact-substring mapping (mirror of IssueDetector.mapCandidates)
    static func mapUnique(_ text: String, _ original: String) -> NSRange? {
        let ns = text as NSString
        var count = 0, start = 0, first = NSRange(location: NSNotFound, length: 0)
        while start < ns.length {
            let r = ns.range(of: original, options: [], range: NSRange(location: start, length: ns.length - start))
            if r.location == NSNotFound { break }
            if count == 0 { first = r }
            count += 1
            start = r.location + max(r.length, 1)
        }
        return count == 1 ? first : nil
    }
    static func testSubstringMapping() {
        check(mapUnique("i has a apple", "has") != nil, "mapping: unique match accepted")
        check(mapUnique("ha ha ha", "ha") == nil, "mapping: duplicate match skipped")
        check(mapUnique("abc def", "xyz") == nil, "mapping: missing match skipped")
    }

    // 10: paragraph proofread output sanitizer (zero-width + wrappers)
    static func testParagraphSanitizer() {
        let zw = ParagraphSanitizer.sanitize("\u{200B}Okay, here's the next attempt.")
        check(zw.text == "Okay, here's the next attempt.", "sanitize: leading zero-width stripped")
        check(zw.zeroWidthStripped == 1, "sanitize: zero-width counted")

        let plain = ParagraphSanitizer.sanitize("Okay, here's the next attempt.")
        check(plain.text == "Okay, here's the next attempt.", "sanitize: clean text untouched")
        check(plain.zeroWidthStripped == 0, "sanitize: no false zero-width")

        let fenced = ParagraphSanitizer.sanitize("```\nFixed text.\n```")
        check(fenced.text == "Fixed text.", "sanitize: code fence unwrapped")

        let quoted = ParagraphSanitizer.sanitize("\"Fixed text.\"")
        check(quoted.text == "Fixed text.", "sanitize: wrapping quotes removed")

        let interior = ParagraphSanitizer.sanitize("He said \"hi\" to me.")
        check(interior.text == "He said \"hi\" to me.", "sanitize: interior quotes preserved")

        let enveloped = TextNormalizer.sanitizeModelOutput(
            "Preface that must not be pasted.\n<bean_output>Fixed text.</bean_output>\nAll looked good.",
            originalCore: "Fixd text.")
        check(enveloped == "Fixed text.", "sanitize: extracts only the Bean output envelope")

        let footer = TextNormalizer.sanitizeModelOutput(
            "This sentence is already clean.\n\nAll looked good.",
            originalCore: "This sentence is already clean.")
        check(footer == "This sentence is already clean.", "sanitize: strips added status footer")

        let legitimateFooter = TextNormalizer.sanitizeModelOutput(
            "Status:\nAll looked good.", originalCore: "Status:\nAll looked good.")
        check(legitimateFooter == "Status:\nAll looked good.", "sanitize: preserves a source-authored footer")

        let sourceTag = TextNormalizer.sanitizeModelOutput(
            "Keep <bean_output>literal</bean_output> markup.",
            originalCore: "Keep <bean_output>literal</bean_output> markup.")
        check(sourceTag == "Keep <bean_output>literal</bean_output> markup.",
              "sanitize: does not mistake a source-authored tag for the response envelope")
    }

    // 8: shortcut equality (mirror of GlobalShortcut value semantics)
    struct SC: Equatable { let keyCode: UInt32; let mods: UInt32 }
    static func testShortcutEquality() {
        check(SC(keyCode: 5, mods: 0x0300) == SC(keyCode: 5, mods: 0x0300), "shortcut: equal combos equal")
        check(SC(keyCode: 5, mods: 0x0300) != SC(keyCode: 11, mods: 0x0900), "shortcut: different combos differ")
    }
}
