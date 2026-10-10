import Foundation
import NaturalLanguage

/// An author's convention, not an instruction to normalize already-valid
/// regional spellings. Explicit choices are passed to the macOS checker without
/// changing its shared language or the user's system spelling preference.
enum WritingDialect: String, CaseIterable, Codable, Identifiable {
    case automatic
    case canadianEnglish = "en_CA"
    case americanEnglish = "en_US"
    case britishEnglish = "en_GB"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .canadianEnglish: return "Canadian English"
        case .americanEnglish: return "American English"
        case .britishEnglish: return "British English"
        }
    }

    var promptInstruction: String? {
        guard self != .automatic else { return nil }
        return "Use \(displayName) for English corrections. Keep the source language and preserve already-valid regional spellings; do not change spelling solely to enforce a dialect."
    }

    func checkerLanguage(systemLanguage: String) -> String {
        self == .automatic ? systemLanguage : rawValue
    }

    struct LanguageResolution {
        let checkerLanguage: String?
        let appliesEnglishRules: Bool
    }

    /// Regional preference never licenses treating another language as broken
    /// English. Detection is used only with strong evidence; short/ambiguous
    /// fragments retain the user's requested/system convention.
    func resolveLanguage(in text: String, systemLanguage: String,
                         availableLanguages: [String]) -> LanguageResolution {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let strongest = recognizer.languageHypotheses(withMaximum: 1).first
        // Repeating a tiny fragment inflates the recognizer's confidence even
        // though it adds no independent language evidence. Confirm a switch
        // away from the requested convention with distinct lexical evidence.
        // A genuine short phrase retains its words; repetition cannot turn a
        // weak guess (such as two typo-heavy tokens) into a confident language.
        var seen = Set<String>()
        let independentWords = text.lowercased().split(whereSeparator: { !$0.isLetter })
            .filter { seen.insert(String($0)).inserted }.prefix(200).map(String.init)
        let evidence = independentWords.joined(separator: " ")
        let independentRecognizer = NLLanguageRecognizer()
        independentRecognizer.processString(evidence)
        let independent = independentRecognizer.languageHypotheses(withMaximum: 1).first
        let detected = evidence.filter({ $0.isLetter }).count >= 12
            && (strongest?.value ?? 0) >= 0.8 && (independent?.value ?? 0) >= 0.8
            && strongest?.key == independent?.key ? strongest?.key.rawValue : nil
        if let detected, detected != "en", detected != "und" {
            let compatible = availableLanguages.first(where: { $0 == detected })
                ?? availableLanguages.sorted().first(where: {
                    $0.replacingOccurrences(of: "-", with: "_").hasPrefix(detected + "_")
                })
            return LanguageResolution(checkerLanguage: compatible, appliesEnglishRules: false)
        }
        let requested = self == .automatic && detected == "en" && !systemLanguage.hasPrefix("en")
            ? availableLanguages.sorted().first(where: { $0.hasPrefix("en") }) ?? systemLanguage
            : checkerLanguage(systemLanguage: systemLanguage)
        // AppKit names its American English dictionary "en" on some macOS
        // versions. Treat that documented base-English service identifier as
        // the US convention, rather than silently disabling half the scans.
        let language = availableLanguages.contains(requested) ? requested
            : requested == "en_US" && availableLanguages.contains("en") ? "en" : nil
        return LanguageResolution(checkerLanguage: language,
                                  appliesEnglishRules: self != .automatic || detected == "en" || requested.hasPrefix("en"))
    }
}
