import Foundation

enum BeanPublicLinks {
    static let repository = URL(string: "https://github.com/aneesio/bean")!
    static let issues = URL(string: "https://github.com/aneesio/bean/issues")!
    static let newBug = URL(string: "https://github.com/aneesio/bean/issues/new?template=bug.yml")!
    static let privacy = URL(string: "https://github.com/aneesio/bean/blob/main/PRIVACY.md")!
    static let license = URL(string: "https://github.com/aneesio/bean/blob/main/LICENSE.md")!
    static let changelog = URL(string: "https://github.com/aneesio/bean/blob/main/CHANGELOG.md")!
    static let support = URL(string: "https://github.com/aneesio/bean/blob/main/SUPPORT.md")!
}

enum SupportRepairAction: Equatable {
    case guidedSetup
    case browserSettings
    case revealApplication
    case none
}

struct SupportRepairCard: Equatable, Identifiable {
    let id: String
    let symbol: String
    let title: String
    let detail: String
    let actionTitle: String?
    let action: SupportRepairAction
}

enum SupportCenter {
    /// Produces only actionable, content-free Mac-side health findings. Browser
    /// setup is optional, so an absent extension is a repair only when browser AI
    /// was enabled. A current native-host manifest proves only that the Mac
    /// connection is installed; live extension status is checked in the extension.
    static func repairCards(
        accessibilityGranted: Bool,
        appLocationWarning: String?,
        runningInstanceCount: Int,
        browserStatus: BrowserBridgeStatus,
        browserAIEnabled: Bool
    ) -> [SupportRepairCard] {
        var cards: [SupportRepairCard] = []

        if !accessibilityGranted {
            cards.append(SupportRepairCard(
                id: "accessibility", symbol: "hand.raised.fill",
                title: "Accessibility needs attention",
                detail: "Bean cannot inspect or update text in other apps until macOS grants access.",
                actionTitle: "Open Guided Setup", action: .guidedSetup
            ))
        }

        if let appLocationWarning {
            cards.append(SupportRepairCard(
                id: "app-location", symbol: "shippingbox.fill",
                title: "Install Bean in Applications",
                detail: appLocationWarning,
                actionTitle: "Reveal Bean", action: .revealApplication
            ))
        }

        if runningInstanceCount > 1 {
            cards.append(SupportRepairCard(
                id: "instances", symbol: "square.on.square",
                title: "More than one Bean is running",
                detail: "Quit the extra copy, then reopen /Applications/Bean.app so shortcuts and permissions use one stable app.",
                actionTitle: nil, action: .none
            ))
        }

        let browserNeedsRepair: Bool
        switch browserStatus.state {
        case .installed:
            browserNeedsRepair = false
        case .unavailable:
            browserNeedsRepair = browserAIEnabled
        case .readyToInstall, .needsRepair:
            browserNeedsRepair = true
        case .extensionNotFound:
            browserNeedsRepair = browserAIEnabled
        }
        if browserNeedsRepair {
            cards.append(SupportRepairCard(
                id: "browser", symbol: "globe",
                title: "Mac browser connection needs attention",
                detail: browserStatus.detail,
                actionTitle: "Open Browser Settings", action: .browserSettings
            ))
        }

        return cards
    }
}

struct SupportReportBuilder {
    let generatedAt: Date

    init(generatedAt: Date = Date()) {
        self.generatedAt = generatedAt
    }

    /// A reviewable report template containing the already content-free
    /// diagnostics summary. It is returned in memory and is never saved or sent.
    func makeReport(diagnostics: String) -> String {
        let timestamp = ISO8601DateFormatter().string(from: generatedAt)
        return """
        Bean support report
        generatedAt: \(timestamp)

        Review every line before sharing. This preview is not saved or uploaded by Bean.

        What happened
        [Describe the problem using synthetic text only.]

        Steps to reproduce
        1. [First step]
        2. [Second step]

        Expected
        [What did you expect?]

        Actual
        [What happened instead?]

        Content-free diagnostics
        ------------------------
        \(diagnostics)
        """
    }
}
