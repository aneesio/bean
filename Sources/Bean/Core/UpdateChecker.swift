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
              url.path.hasPrefix("/aneesio/bean/releases/") else {
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

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub returned an unreadable response. Try again later."
        case .requestFailed(let status):
            return "GitHub returned HTTP \(status). Check your connection or try again later."
        case .noPublicRelease:
            return "No published Bean release was found on GitHub."
        case .invalidReleasePage:
            return "GitHub returned an unverified release link. Open the Bean repository manually."
        }
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var state: UpdateCheckState = .idle

    private static let endpoint = URL(
        string: "https://api.github.com/repos/aneesio/bean/releases?per_page=20"
    )!

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

                let configuration = URLSessionConfiguration.ephemeral
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                let session = URLSession(configuration: configuration)
                let (data, response) = try await session.data(for: request)
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
                state = Self.isVersion(release.tagName, newerThan: AppInfo.version)
                    ? .updateAvailable(release) : .upToDate(release)
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failure(error.localizedDescription)
            }
        }
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
        guard let candidate = SemanticVersion(candidate),
              let installed = SemanticVersion(installed) else {
            return false
        }
        return candidate > installed
    }
}

private struct SemanticVersion: Comparable {
    let components: [Int]
    let prerelease: String?

    init?(_ rawValue: String) {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("v") { value.removeFirst() }
        value = value.split(separator: "+", maxSplits: 1).first.map(String.init) ?? value
        let parts = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numberParts = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard !numberParts.isEmpty,
              numberParts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        components = numberParts.compactMap { Int($0) }
        guard components.count == numberParts.count else { return nil }
        prerelease = parts.count == 2 && !parts[1].isEmpty ? String(parts[1]) : nil
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
        case let (.some(left), .some(right)): return left < right
        case (.none, .none): return false
        }
    }
}
