import Foundation
import XCTest
@testable import Bean

@MainActor
final class AppLocationServiceTests: XCTestCase {
    private let source = URL(fileURLWithPath: "/Users/test/Downloads/Bean.app", isDirectory: true)
    private let destination = URL(fileURLWithPath: "/Applications/Bean.app", isDirectory: true)

    func testCanonicalApplicationsPathIsTheOnlyStableLocation() {
        let stable = AppLocationAssessment(appURL: destination)
        XCTAssertEqual(stable.kind, .applications)
        XCTAssertTrue(stable.isStable)
        XCTAssertNil(stable.warningMessage)

        let cases: [(String, AppLocationAssessment.Kind)] = [
            ("/Users/test/Downloads/Bean.app", .downloads),
            ("/Users/test/project/build/Bean.app", .buildFolder),
            ("/Users/test/project/.build/Bean.app", .buildFolder),
            ("/Users/test/Library/Developer/Xcode/DerivedData/Bean-a/Build/Products/Bean.app", .derivedData),
            ("/private/var/folders/xy/AppTranslocation/ABC/d/Bean.app", .appTranslocation),
            ("/Users/test/Desktop/Bean.app", .other),
            ("/Applications/Bean Beta.app", .other)
        ]

        for (path, expectedKind) in cases {
            let assessment = AppLocationAssessment(appURL: URL(fileURLWithPath: path, isDirectory: true))
            XCTAssertEqual(assessment.kind, expectedKind, path)
            XCTAssertFalse(assessment.isStable, path)
            XCTAssertFalse(assessment.reason.isEmpty, path)
            XCTAssertTrue(assessment.warningMessage?.contains("Install Bean in Applications") == true, path)
        }
    }

    func testDestinationCollisionNeverCopiesAndCanOpenInstalledCopy() async throws {
        let recorder = EffectsRecorder(existing: [source.path, destination.path])
        let service = makeService(recorder)

        do {
            try await service.installAndRelaunch()
            XCTFail("Expected destination collision")
        } catch let error as AppLocationServiceError {
            XCTAssertEqual(error, .destinationAlreadyExists(destination.path))
        }
        XCTAssertEqual(recorder.operations, [])
        XCTAssertFalse(recorder.didTerminate)

        let openedURL = try await service.openInstalledCopy()
        XCTAssertEqual(openedURL, destination)
        XCTAssertEqual(recorder.operations, ["launch:\(destination.path)", "terminate"])
        XCTAssertTrue(recorder.didTerminate)
    }

    func testInstallCopiesToSiblingThenMovesBeforeLaunchAndTerminate() async throws {
        let recorder = EffectsRecorder(existing: [source.path])
        let service = makeService(recorder)

        let result = try await service.installAndRelaunch()

        let temporary = "/Applications/.Bean-installing-test-id.app"
        XCTAssertEqual(result, destination)
        XCTAssertEqual(recorder.operations, [
            "copy:\(source.path)->\(temporary)",
            "move:\(temporary)->\(destination.path)",
            "launch:\(destination.path)",
            "terminate"
        ])
        XCTAssertFalse(recorder.existing.contains(temporary))
        XCTAssertTrue(recorder.existing.contains(destination.path))
        XCTAssertTrue(recorder.didTerminate)
    }

    func testCopyFailureCleansPartialTemporaryCopyAndDoesNotLaunch() async {
        let recorder = EffectsRecorder(existing: [source.path])
        recorder.copyError = StubError(message: "copy refused")
        let service = makeService(recorder)

        do {
            try await service.installAndRelaunch()
            XCTFail("Expected copy failure")
        } catch let error as AppLocationServiceError {
            XCTAssertEqual(error, .copyFailed("copy refused"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(recorder.operations, [
            "copy:\(source.path)->/Applications/.Bean-installing-test-id.app",
            "remove:/Applications/.Bean-installing-test-id.app"
        ])
        XCTAssertFalse(recorder.didTerminate)
        XCTAssertFalse(recorder.existing.contains(destination.path))
    }

    func testMoveFailureCleansTemporaryCopyAndDoesNotLaunch() async {
        let recorder = EffectsRecorder(existing: [source.path])
        recorder.moveError = StubError(message: "move refused")
        let service = makeService(recorder)

        do {
            try await service.installAndRelaunch()
            XCTFail("Expected install failure")
        } catch let error as AppLocationServiceError {
            XCTAssertEqual(error, .installFailed("move refused"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(recorder.operations, [
            "copy:\(source.path)->/Applications/.Bean-installing-test-id.app",
            "move:/Applications/.Bean-installing-test-id.app->\(destination.path)",
            "remove:/Applications/.Bean-installing-test-id.app"
        ])
        XCTAssertFalse(recorder.didTerminate)
        XCTAssertFalse(recorder.existing.contains(destination.path))
    }

    func testLaunchFailureLeavesInstalledCopyAndNeverTerminatesCurrentApp() async {
        let recorder = EffectsRecorder(existing: [source.path])
        recorder.launchError = StubError(message: "launch refused")
        let service = makeService(recorder)

        do {
            try await service.installAndRelaunch()
            XCTFail("Expected launch failure")
        } catch let error as AppLocationServiceError {
            XCTAssertEqual(error, .launchFailed("launch refused"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(recorder.existing.contains(destination.path))
        XCTAssertEqual(recorder.operations.last, "launch:\(destination.path)")
        XCTAssertFalse(recorder.didTerminate)
    }

    func testMissingSourceAndMissingInstalledCopyAreTypedFailures() async {
        let recorder = EffectsRecorder(existing: [])
        let service = makeService(recorder)

        do {
            try await service.installAndRelaunch()
            XCTFail("Expected missing source")
        } catch let error as AppLocationServiceError {
            XCTAssertEqual(error, .sourceMissing(source.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            try await service.openInstalledCopy()
            XCTFail("Expected missing installed copy")
        } catch let error as AppLocationServiceError {
            XCTAssertEqual(error, .installedCopyMissing(destination.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(recorder.operations, [])
        XCTAssertFalse(recorder.didTerminate)
    }

    private func makeService(_ recorder: EffectsRecorder) -> AppLocationService {
        AppLocationService(
            currentApplicationURL: source,
            installedApplicationURL: destination,
            effects: recorder.effects
        )
    }
}

private struct StubError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class EffectsRecorder {
    var existing: Set<String>
    var operations: [String] = []
    var copyError: Error?
    var moveError: Error?
    var launchError: Error?
    var didTerminate = false

    init(existing: Set<String>) {
        self.existing = existing
    }

    var effects: AppLocationEffects {
        AppLocationEffects(
            fileExists: { [self] in existing.contains($0.path) },
            copyItem: { [self] source, destination in
                operations.append("copy:\(source.path)->\(destination.path)")
                existing.insert(destination.path) // also models a partial copy
                if let copyError { throw copyError }
            },
            moveItem: { [self] source, destination in
                operations.append("move:\(source.path)->\(destination.path)")
                if let moveError { throw moveError }
                guard !existing.contains(destination.path) else {
                    throw StubError(message: "destination exists")
                }
                existing.remove(source.path)
                existing.insert(destination.path)
            },
            removeItem: { [self] url in
                operations.append("remove:\(url.path)")
                existing.remove(url.path)
            },
            launchApplication: { [self] url in
                operations.append("launch:\(url.path)")
                if let launchError { throw launchError }
            },
            terminateCurrentApplication: { [self] in
                operations.append("terminate")
                didTerminate = true
            },
            makeTemporaryIdentifier: { "test-id" }
        )
    }
}
