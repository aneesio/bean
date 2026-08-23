import Foundation

struct GitHubRelease: Decodable, Equatable {
    let tagName: String
    let pageURLString: String
    let isPrerelease: Bool
    let isDraft: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case pageURLString = "html_url"
        case isPrerelease = "prerelease"
        case isDraft = "draft"
    }

    /// Only release pages owned by Bean's canonical repository are opened.
    var verifiedPageURL: URL? {
        guard let url = URL(string: pageURLString),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com",
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.fragment == nil else {
            return nil
        }

        // Compare decoded path components rather than an unnormalized prefix.
        // A raw path such as `/releases/../../other` otherwise looks canonical
        // before the browser resolves its dot segments. Binding the final
        // component to `tagName` also prevents a mismatched release page from
        // being presented as the version Bean just compared.
        let pathComponents = url.pathComponents
        guard !pathComponents.contains(where: { $0 == "." || $0 == ".." }),
              pathComponents == [
                  "/", "aneesio", "bean", "releases", "tag", tagName
              ] else {
            return nil
        }
        return url
    }
}

enum UpdateCheckState: Equatable {
    case idle
    case checking
    case upToDate(GitHubRelease)
    case updateAvailable(GitHubRelease)
    case failure(String)
}

enum UpdateCheckError: LocalizedError {
    case invalidResponse
    case requestFailed(Int)
    case noPublicRelease
    case invalidReleasePage
    case invalidVersionMetadata

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub returned an unreadable response. Try again later."
        case .requestFailed(403), .requestFailed(429):
            return "GitHub is temporarily limiting update checks. Wait a few minutes, then try again."
        case .requestFailed(let status):
            return "GitHub returned HTTP \(status). Check your connection or try again later."
        case .noPublicRelease:
            return "No published Bean release was found on GitHub."
        case .invalidReleasePage:
            return "GitHub returned an unverified release link. Open the Bean repository manually."
        case .invalidVersionMetadata:
            return "Bean couldn't compare the published version. Open the Bean repository manually."
        }
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    @Published private(set) var state: UpdateCheckState = .idle

    private let transport: Transport

    private static let endpoint = URL(
        string: "https://api.github.com/repos/aneesio/bean/releases?per_page=20"
    )!

    init(transport: @escaping Transport = { request in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        return try await session.data(for: request)
    }) {
        self.transport = transport
    }

    /// Deliberately user-triggered. Bean never calls this from launch, a timer,
    /// or a background task and never downloads or installs release assets.
    func check() {
        guard state != .checking else { return }
        state = .checking

        Task { [weak self] in
            guard let self else { return }
            do {
                var request = URLRequest(url: Self.endpoint)
                request.httpMethod = "GET"
                request.timeoutInterval = 15
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("Bean/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")

                let (data, response) = try await transport(request)
                guard let response = response as? HTTPURLResponse else {
                    throw UpdateCheckError.invalidResponse
                }
                guard (200...299).contains(response.statusCode) else {
                    throw UpdateCheckError.requestFailed(response.statusCode)
                }

                let release = try Self.latestPublishedRelease(from: data)
                guard release.verifiedPageURL != nil else {
                    throw UpdateCheckError.invalidReleasePage
                }
                state = try Self.releaseIsNewer(
                    release.tagName,
                    than: AppInfo.version
                )
                    ? .updateAvailable(release) : .upToDate(release)
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failure(Self.actionableFailureMessage(for: error))
            }
        }
    }

    nonisolated static func actionableFailureMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return "You're offline. Connect to the internet, then try again."
            case .timedOut:
                return "The update check timed out. Check your connection, then try again."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                 .networkConnectionLost:
                return "Bean couldn't reach GitHub. Check your connection, then try again."
            default:
                return "Bean couldn't check for updates. Check your connection, then try again."
            }
        }
        if let updateError = error as? UpdateCheckError,
           let description = updateError.errorDescription {
            return description
        }
        return "Bean couldn't check for updates. Try again later."
    }

    nonisolated static func latestPublishedRelease(from data: Data) throws -> GitHubRelease {
        let releases: [GitHubRelease]
        do {
            releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        } catch {
            throw UpdateCheckError.invalidResponse
        }
        guard let release = releases.first(where: { !$0.isDraft }) else {
            throw UpdateCheckError.noPublicRelease
        }
        return release
    }

    nonisolated static func isVersion(_ candidate: String, newerThan installed: String) -> Bool {
        (try? releaseIsNewer(candidate, than: installed)) ?? false
    }

    private nonisolated static func releaseIsNewer(
        _ candidate: String,
        than installed: String
    ) throws -> Bool {
        guard let candidate = SemanticVersion(candidate),
              let installed = SemanticVersion(installed) else {
            throw UpdateCheckError.invalidVersionMetadata
        }
        return candidate > installed
    }
}

private struct SemanticVersion: Comparable {
    let components: [Int]
    private let prerelease: [PrereleaseIdentifier]?

    private struct PrereleaseIdentifier: Comparable {
        let rawValue: String
        let isNumeric: Bool

        init?(_ rawValue: String) {
            guard !rawValue.isEmpty,
                  rawValue.unicodeScalars.allSatisfy({ scalar in
                      switch scalar.value {
                      case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D:
                          return true
                      default:
                          return false
                      }
                  }) else {
                return nil
            }
            isNumeric = rawValue.unicodeScalars.allSatisfy {
                (0x30...0x39).contains($0.value)
            }
            // SemVer numeric identifiers must not contain leading zeroes.
            guard !isNumeric || rawValue.count == 1 || rawValue.first != "0" else {
                return nil
            }
            self.rawValue = rawValue
        }

        static func < (lhs: PrereleaseIdentifier, rhs: PrereleaseIdentifier) -> Bool {
            switch (lhs.isNumeric, rhs.isNumeric) {
            case (true, true):
                // Numeric identifiers can exceed Int. Comparing digit count and
                // then ASCII text preserves arbitrary-precision numeric order.
                if lhs.rawValue.count != rhs.rawValue.count {
                    return lhs.rawValue.count < rhs.rawValue.count
                }
                return lhs.rawValue < rhs.rawValue
            case (true, false):
                return true
            case (false, true):
                return false
            case (false, false):
                return lhs.rawValue < rhs.rawValue
            }
        }
    }

    init?(_ rawValue: String) {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("v") { value.removeFirst() }
        let buildParts = value.split(
            separator: "+",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        if buildParts.count == 2 {
            guard Self.validBuildMetadata(String(buildParts[1])) else { return nil }
            value = String(buildParts[0])
        }
        let parts = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numberParts = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard !numberParts.isEmpty,
              numberParts.allSatisfy({ part in
                  !part.isEmpty
                      && part.unicodeScalars.allSatisfy {
                          (0x30...0x39).contains($0.value)
                      }
                      && (part.count == 1 || part.first != "0")
              }) else {
            return nil
        }
        components = numberParts.compactMap { Int($0) }
        guard components.count == numberParts.count else { return nil }
        if parts.count == 2 {
            let identifiers = parts[1].split(
                separator: ".",
                omittingEmptySubsequences: false
            ).compactMap { PrereleaseIdentifier(String($0)) }
            guard !identifiers.isEmpty,
                  identifiers.count == parts[1].split(
                      separator: ".",
                      omittingEmptySubsequences: false
                  ).count else {
                return nil
            }
            prerelease = identifiers
        } else {
            prerelease = nil
        }
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (.some, .none): return true
        case (.none, .some): return false
        case let (.some(left), .some(right)):
            for (leftIdentifier, rightIdentifier) in zip(left, right) {
                if leftIdentifier != rightIdentifier {
                    return leftIdentifier < rightIdentifier
                }
            }
            return left.count < right.count
        case (.none, .none): return false
        }
    }

    private static func validBuildMetadata(_ value: String) -> Bool {
        let identifiers = value.split(separator: ".", omittingEmptySubsequences: false)
        return !identifiers.isEmpty && identifiers.allSatisfy { identifier in
            !identifier.isEmpty && identifier.unicodeScalars.allSatisfy { scalar in
                switch scalar.value {
                case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D:
                    return true
                default:
                    return false
                }
            }
        }
    }
}
