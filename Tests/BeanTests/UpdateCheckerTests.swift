import XCTest
@testable import Bean

final class UpdateCheckerTests: XCTestCase {
    private func releaseData(
        tag: String,
        pageURL: String,
        prerelease: Bool = false,
        draft: Bool = false
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [[
            "tag_name": tag,
            "html_url": pageURL,
            "prerelease": prerelease,
            "draft": draft
        ]])
    }

    @MainActor
    private func settledState(of checker: UpdateChecker) async -> UpdateCheckState {
        checker.check()
        for _ in 0..<1_000 {
            if checker.state != .checking { return checker.state }
            await Task.yield()
        }
        XCTFail("Update check did not settle")
        return checker.state
    }

    func testSelectsFirstPublishedReleaseAndDecodesPrerelease() throws {
        let data = Data(#"""
        [
          {"tag_name":"v9.0.0","html_url":"https://github.com/aneesio/bean/releases/tag/v9.0.0","prerelease":false,"draft":true},
          {"tag_name":"v1.3.0","html_url":"https://github.com/aneesio/bean/releases/tag/v1.3.0","prerelease":true,"draft":false},
          {"tag_name":"v1.2.0","html_url":"https://github.com/aneesio/bean/releases/tag/v1.2.0","prerelease":true,"draft":false}
        ]
        """#.utf8)

        let release = try UpdateChecker.latestPublishedRelease(from: data)
        XCTAssertEqual(release.tagName, "v1.3.0")
        XCTAssertTrue(release.isPrerelease)
        XCTAssertEqual(release.verifiedPageURL?.absoluteString,
                       "https://github.com/aneesio/bean/releases/tag/v1.3.0")
    }

    func testReleasePageMustBelongToCanonicalHTTPSRepository() throws {
        let valid = GitHubRelease(
            tagName: "v1.3.0",
            pageURLString: "https://github.com/aneesio/bean/releases/tag/v1.3.0",
            isPrerelease: true,
            isDraft: false
        )
        XCTAssertNotNil(valid.verifiedPageURL)

        for value in [
            "http://github.com/aneesio/bean/releases/tag/v1.3.0",
            "https://evil.example/aneesio/bean/releases/tag/v1.3.0",
            "https://github.com/other/bean/releases/tag/v1.3.0",
            "https://user@github.com/aneesio/bean/releases/tag/v1.3.0",
            "https://github.com/aneesio/bean/releases/../../evil",
            "https://github.com/aneesio/bean/releases/%2e%2e/%2e%2e/evil",
            "https://github.com/aneesio/bean/releases/tag/v9.9.9",
            "https://github.com/aneesio/bean/releases/tag/v1.3.0?redirect=elsewhere"
        ] {
            let release = GitHubRelease(tagName: "v1.3.0", pageURLString: value,
                                        isPrerelease: false, isDraft: false)
            XCTAssertNil(release.verifiedPageURL, value)
        }
    }

    func testSemanticVersionComparison() {
        XCTAssertTrue(UpdateChecker.isVersion("v1.3.0", newerThan: "1.2.9"))
        XCTAssertTrue(UpdateChecker.isVersion("2.0", newerThan: "1.99.99"))
        XCTAssertTrue(UpdateChecker.isVersion("1.3.0", newerThan: "1.3.0-beta.1"))
        XCTAssertFalse(UpdateChecker.isVersion("v1.2.0", newerThan: "1.2.0"))
        XCTAssertFalse(UpdateChecker.isVersion("1.2.0-beta.2", newerThan: "1.2.0"))
        XCTAssertFalse(UpdateChecker.isVersion("not-a-version", newerThan: "1.2.0"))

        XCTAssertTrue(UpdateChecker.isVersion(
            "1.3.0-beta.10",
            newerThan: "1.3.0-beta.9"
        ))
        XCTAssertFalse(UpdateChecker.isVersion(
            "1.3.0-beta.2",
            newerThan: "1.3.0-beta.10"
        ))
        XCTAssertTrue(UpdateChecker.isVersion(
            "1.3.0-alpha",
            newerThan: "1.3.0-10"
        ), "numeric prerelease identifiers sort before nonnumeric identifiers")
        XCTAssertTrue(UpdateChecker.isVersion(
            "1.3.0-beta.1",
            newerThan: "1.3.0-beta"
        ), "a longer equal prerelease identifier list has higher precedence")
        XCTAssertFalse(UpdateChecker.isVersion(
            "1.3.0-beta.01",
            newerThan: "1.3.0-beta.0"
        ), "SemVer numeric identifiers with leading zeroes are invalid")
    }

    func testMalformedAndEmptyResponsesFailClosed() {
        XCTAssertThrowsError(try UpdateChecker.latestPublishedRelease(from: Data("{}".utf8)))
        XCTAssertThrowsError(try UpdateChecker.latestPublishedRelease(from: Data("[]".utf8)))
    }

    @MainActor
    func testTransportFixturesMapCurrentNewerAndPrereleaseStates() async throws {
        struct Fixture {
            let tag: String
            let prerelease: Bool
            let expectsUpdate: Bool
        }
        let fixtures = [
            Fixture(tag: "v\(AppInfo.version)", prerelease: false, expectsUpdate: false),
            Fixture(tag: "v999.0.0", prerelease: false, expectsUpdate: true),
            Fixture(tag: "v999.1.0-beta.1", prerelease: true, expectsUpdate: true)
        ]

        for fixture in fixtures {
            let page = "https://github.com/aneesio/bean/releases/tag/\(fixture.tag)"
            let data = try releaseData(
                tag: fixture.tag,
                pageURL: page,
                prerelease: fixture.prerelease
            )
            let checker = UpdateChecker { request in
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(
                    request.url?.absoluteString,
                    "https://api.github.com/repos/aneesio/bean/releases?per_page=20"
                )
                XCTAssertNil(request.httpBody)
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Accept"),
                    "application/vnd.github+json"
                )
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "User-Agent"),
                    "Bean/\(AppInfo.version)"
                )
                return (
                    data,
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }

            switch await settledState(of: checker) {
            case .upToDate(let release):
                XCTAssertFalse(fixture.expectsUpdate, fixture.tag)
                XCTAssertEqual(release.tagName, fixture.tag)
                XCTAssertEqual(release.isPrerelease, fixture.prerelease)
            case .updateAvailable(let release):
                XCTAssertTrue(fixture.expectsUpdate, fixture.tag)
                XCTAssertEqual(release.tagName, fixture.tag)
                XCTAssertEqual(release.isPrerelease, fixture.prerelease)
            default:
                XCTFail("Unexpected state for \(fixture.tag): \(checker.state)")
            }
        }
    }

    @MainActor
    func testOfflineAndRateLimitFailuresAreActionable() async throws {
        let offline = UpdateChecker { _ in
            throw URLError(.notConnectedToInternet)
        }
        let offlineState = await settledState(of: offline)
        XCTAssertEqual(
            offlineState,
            .failure("You're offline. Connect to the internet, then try again.")
        )

        for statusCode in [403, 429] {
            let rateLimited = UpdateChecker { request in
                (
                    Data(),
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: statusCode,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            }
            let rateLimitState = await settledState(of: rateLimited)
            guard case .failure(let message) = rateLimitState else {
                return XCTFail(
                    "Expected an HTTP \(statusCode) failure, got \(rateLimitState)"
                )
            }
            XCTAssertTrue(message.localizedCaseInsensitiveContains("limiting update checks"))
            XCTAssertTrue(message.localizedCaseInsensitiveContains("try again"))
        }
    }

    @MainActor
    func testMalformedAndHostileReleaseFixturesFailClosedWithRecoveryText() async throws {
        let malformed = UpdateChecker { request in
            (
                Data(#"{"unexpected":true}"#.utf8),
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url), statusCode: 200,
                    httpVersion: nil, headerFields: nil
                )!
            )
        }
        let malformedState = await settledState(of: malformed)
        XCTAssertEqual(
            malformedState,
            .failure("GitHub returned an unreadable response. Try again later.")
        )

        let hostileData = try releaseData(
            tag: "v999.0.0",
            pageURL: "https://evil.example/aneesio/bean/releases/tag/v999.0.0"
        )
        let hostile = UpdateChecker { request in
            (
                hostileData,
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url), statusCode: 200,
                    httpVersion: nil, headerFields: nil
                )!
            )
        }
        let hostileState = await settledState(of: hostile)
        XCTAssertEqual(
            hostileState,
            .failure("GitHub returned an unverified release link. Open the Bean repository manually.")
        )

        let invalidVersionData = try releaseData(
            tag: "not-a-version",
            pageURL: "https://github.com/aneesio/bean/releases/tag/not-a-version"
        )
        let invalidVersion = UpdateChecker { request in
            (
                invalidVersionData,
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url), statusCode: 200,
                    httpVersion: nil, headerFields: nil
                )!
            )
        }
        let invalidVersionState = await settledState(of: invalidVersion)
        XCTAssertEqual(
            invalidVersionState,
            .failure("Bean couldn't compare the published version. Open the Bean repository manually.")
        )
    }

    func testUpdateCheckerCannotDownloadInstallOrLaunchReleaseAssets() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Bean/Core/UpdateChecker.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("session.data(for: request)"))
        for forbidden in ["downloadTask(", "download(from:", "FileManager.",
                          "Process(", "NSWorkspace.shared.open"] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
    }
}
