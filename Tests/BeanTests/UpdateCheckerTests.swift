import XCTest
@testable import Bean

final class UpdateCheckerTests: XCTestCase {
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
            "https://user@github.com/aneesio/bean/releases/tag/v1.3.0"
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
    }

    func testMalformedAndEmptyResponsesFailClosed() {
        XCTAssertThrowsError(try UpdateChecker.latestPublishedRelease(from: Data("{}".utf8)))
        XCTAssertThrowsError(try UpdateChecker.latestPublishedRelease(from: Data("[]".utf8)))
    }
}
