import AppKit
import XCTest
@testable import Bean

final class ReplacementUndoStoreTests: XCTestCase {
    @MainActor
    private final class Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            opened = true
            let pending = waiters; waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    @MainActor
    private func register(_ store: ReplacementUndoStore, original: String = "teh", replacement: String = "the") -> AXUIElement {
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        store.registerConfirmedWholeField(app: .current, element: element, original: original, replacement: replacement)
        return element
    }

    @MainActor
    func testUnconfirmedUndoConsumesRecordEvenWhileOutputIsStillUnchanged() async {
        var field = "the", deliveries = 0
        let store = ReplacementUndoStore(effects: .init(activateAndValidate: { _, _ in true },
            readValue: { _ in field }, selectedRange: { _ in NSRange(location: 3, length: 0) },
            apply: { _, _ in deliveries += 1; return .init(result: .replacementSentUnconfirmed, didAttemptDelivery: true) }))
        _ = register(store)
        let outcome = await store.undo()
        XCTAssertEqual(outcome, .replacementSentUnconfirmed)
        XCTAssertFalse(store.isAvailable)
        field = "teh" // The original inverse eventually lands after its deadline.
        if case .failed = await store.undo() {} else { XCTFail("A delayed inverse must not be sent twice") }
        XCTAssertEqual(deliveries, 1)
        XCTAssertEqual(field, "teh")
    }

    @MainActor
    func testPartialOrFalseSetterUndoCannotResurrectOriginalRecord() async {
        for result in [TextSelectionService.ReplacementResult.replacementSentUnconfirmed, .failed(reason: "Stopped after one verified span")] {
            let store = ReplacementUndoStore(effects: .init(activateAndValidate: { _, _ in true },
                readValue: { _ in "the" }, selectedRange: { _ in nil },
                apply: { _, _ in .init(result: result, didAttemptDelivery: true) }))
            _ = register(store)
            let outcome = await store.undo()
            XCTAssertEqual(outcome, result)
            XCTAssertFalse(store.isAvailable, "Unchanged readback cannot prove a delivered inverse won't arrive later")
        }
    }

    @MainActor
    func testUnconfirmedOrConfirmedUndoCannotRestoreRecordEvenIfDeliveryFlagIsMissing() async {
        for result in [TextSelectionService.ReplacementResult.replacementSentUnconfirmed, .replacedConfirmed, .noChangesNeeded] {
            let store = ReplacementUndoStore(effects: .init(activateAndValidate: { _, _ in true },
                readValue: { _ in "the" }, selectedRange: { _ in nil },
                apply: { _, _ in .init(result: result, didAttemptDelivery: false) }))
            _ = register(store)
            let outcome = await store.undo()
            XCTAssertEqual(outcome, result)
            XCTAssertFalse(store.isAvailable, "Only an explicit refusal before delivery may preserve a record")
        }
    }

    @MainActor
    func testSafePreTransportRefusalRetainsExactRecord() async {
        let result = TextSelectionService.ReplacementResult.failed(reason: "Range is unavailable before delivery")
        let store = ReplacementUndoStore(effects: .init(activateAndValidate: { _, _ in true },
            readValue: { _ in "the" }, selectedRange: { _ in nil },
            apply: { _, _ in .init(result: result, didAttemptDelivery: false) }))
        let element = register(store)
        let outcome = await store.undo()
        XCTAssertEqual(outcome, result)
        XCTAssertTrue(store.isAvailable(for: element, value: "the", app: .current))
    }

    @MainActor
    func testConcurrentUndoIsUnavailableAndNeverSendsASecondInverse() async {
        let entered = Gate(), release = Gate()
        var deliveries = 0
        let store = ReplacementUndoStore(effects: .init(activateAndValidate: { _, _ in true },
            readValue: { _ in "the" }, selectedRange: { _ in nil }, apply: { _, _ in
                deliveries += 1; entered.open(); await release.wait()
                return .init(result: .replacementSentUnconfirmed, didAttemptDelivery: true)
            }))
        _ = register(store)
        let first = Task { await store.undo() }
        await entered.wait()
        XCTAssertFalse(store.isAvailable)
        let concurrent = await store.undo()
        XCTAssertEqual(concurrent, .failed(reason: "Bean is already undoing a change."))
        XCTAssertEqual(deliveries, 1)
        release.open()
        let outcome = await first.value
        XCTAssertEqual(outcome, .replacementSentUnconfirmed)
        XCTAssertFalse(store.isAvailable)
    }

    @MainActor
    func testNewerRecordBeforeActivationCompletesPreventsOldUndoDelivery() async {
        let entered = Gate(), release = Gate()
        var deliveries = 0
        let store = ReplacementUndoStore(effects: .init(activateAndValidate: { _, _ in
                entered.open(); await release.wait(); return true
            }, readValue: { _ in "new output" }, selectedRange: { _ in nil },
            apply: { _, _ in deliveries += 1; return .init(result: .replacedConfirmed, didAttemptDelivery: true) }))
        _ = register(store)
        let first = Task { await store.undo() }
        await entered.wait()
        let element = register(store, original: "new original", replacement: "new output")
        release.open()
        if case .failed = await first.value {} else { XCTFail("An old claim cannot override a newer record") }
        XCTAssertEqual(deliveries, 0)
        XCTAssertTrue(store.isAvailable(for: element, value: "new output", app: .current))
    }

    @MainActor
    func testOldUndoCompletionNeverErasesNewerRecord() async {
        for result in [TextSelectionService.ReplacementResult.replacedConfirmed, .replacementSentUnconfirmed] {
            let entered = Gate(), release = Gate()
            let store = ReplacementUndoStore(effects: .init(activateAndValidate: { _, _ in true },
                readValue: { _ in "the" }, selectedRange: { _ in nil }, apply: { _, _ in
                    entered.open(); await release.wait(); return .init(result: result, didAttemptDelivery: true)
                }))
            _ = register(store)
            let first = Task { await store.undo() }
            await entered.wait()
            let element = register(store, original: "new original", replacement: "new output")
            release.open()
            let outcome = await first.value
            XCTAssertEqual(outcome, result)
            XCTAssertTrue(store.isAvailable(for: element, value: "new output", app: .current))
            XCTAssertFalse(store.isAvailable(for: element, value: "the", app: .current))
        }
    }

    @MainActor
    func testDiscardDuringZeroDeliveryRefusalPreventsOldRecordRestoration() async {
        let entered = Gate(), release = Gate()
        let store = ReplacementUndoStore(effects: .init(activateAndValidate: { _, _ in true },
            readValue: { _ in "the" }, selectedRange: { _ in nil }, apply: { _, _ in
                entered.open(); await release.wait()
                return .init(result: .failed(reason: "Refused before delivery"), didAttemptDelivery: false)
            }))
        _ = register(store)
        let first = Task { await store.undo() }
        await entered.wait(); store.discard(); release.open()
        _ = await first.value
        XCTAssertFalse(store.isAvailable)
    }

    @MainActor
    func testFocusRefusalPreservesRecordAndUnreadableValueRetiresItWithoutTransport() async {
        let focus = ReplacementUndoStore(effects: .init(activateAndValidate: { _, _ in false },
            readValue: { _ in XCTFail("Focus must be proven before read"); return nil }, selectedRange: { _ in nil },
            apply: { _, _ in XCTFail("No transport is allowed"); return .init(result: .noChangesNeeded, didAttemptDelivery: false) }))
        _ = register(focus)
        if case .failed = await focus.undo() {} else { XCTFail("Wrong destination must refuse") }
        XCTAssertTrue(focus.isAvailable)
        let unreadable = ReplacementUndoStore(effects: .init(activateAndValidate: { _, _ in true },
            readValue: { _ in nil }, selectedRange: { _ in XCTFail("No range query is allowed"); return nil },
            apply: { _, _ in XCTFail("No transport is allowed"); return .init(result: .noChangesNeeded, didAttemptDelivery: false) }))
        _ = register(unreadable)
        if case .failed = await unreadable.undo() {} else { XCTFail("Unverifiable source must refuse") }
        XCTAssertFalse(unreadable.isAvailable)
    }

    @MainActor
    func testUndoAvailabilityMatchesStoredTargetAndExactOutputWithoutLiveReads() throws {
        let store = ReplacementUndoStore()
        let app = NSRunningApplication.current
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let other = AXUIElementCreateSystemWide()
        let plan = try XCTUnwrap(NativeEditPlan.proofread(original: "teh café", corrected: "the café"))
        store.registerConfirmedEdits(app: app, element: element, plan: plan)
        XCTAssertTrue(store.isAvailable(for: element, value: "the café", app: app))
        XCTAssertFalse(store.isAvailable(for: other, value: "the café", app: app))
        XCTAssertFalse(store.isAvailable(for: element, value: "the cafe\u{301}", app: app))
        XCTAssertFalse(store.isAvailable(for: element, value: "the newer café", app: app))
        XCTAssertFalse(store.isAvailable(for: element, value: "the café", app: nil))
    }

    func testConfirmedSelectedEditSupportsUndoWithoutRequiringWholeFieldWrite() {
        let original = "Please fix teh sentence."
        XCTAssertTrue(ReplacementUndoStore.canRegisterRangeUndo(
            original: original, replacement: "Please fix the sentence.",
            range: (original as NSString).range(of: "teh"),
            originalRangeText: "teh", replacementRangeText: "the"
        ))
    }

    func testUnexpectedFieldChangeCannotBecomeAnUndoRecord() {
        let original = "Please fix teh sentence."
        XCTAssertFalse(ReplacementUndoStore.canRegisterRangeUndo(
            original: original, replacement: "Please fix the newer sentence.",
            range: (original as NSString).range(of: "teh"),
            originalRangeText: "teh", replacementRangeText: "the"
        ))
    }

    func testRepeatedTextMustUseTheCapturedOccurrenceForUndo() {
        let original = "teh first and teh second"
        XCTAssertFalse(ReplacementUndoStore.canRegisterRangeUndo(
            original: original, replacement: "teh first and the second",
            range: NSRange(location: 0, length: 3),
            originalRangeText: "teh", replacementRangeText: "the"
        ), "A correction at the second occurrence cannot prove a first-occurrence undo")
        XCTAssertTrue(ReplacementUndoStore.canRegisterRangeUndo(
            original: original, replacement: "teh first and the second",
            range: NSRange(location: 14, length: 3),
            originalRangeText: "teh", replacementRangeText: "the"
        ))
    }

    func testCanonicalEquivalentFieldChangeCannotBeUndoneFromOldUTF16Offsets() {
        XCTAssertFalse(ReplacementUndoStore.currentValueMatches(
            "the cafe\u{301}", expectedReplacement: "the café"
        ))
        XCTAssertTrue(ReplacementUndoStore.currentValueMatches(
            "the café", expectedReplacement: "the café"
        ))
        XCTAssertFalse(ReplacementUndoStore.canRegisterRangeUndo(
            original: "teh café", replacement: "the cafe\u{301}",
            range: NSRange(location: 0, length: 3),
            originalRangeText: "teh", replacementRangeText: "the"
        ), "Unrelated normalization is not the exact predicted range edit")
    }

    @MainActor
    func testConfirmedEditWithoutAnExactUndoRangeRetiresThePreviousRecord() async {
        let store = ReplacementUndoStore()
        store.registerConfirmedWholeField(
            app: .current,
            element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier),
            original: "An earlier teh edit", replacement: "An earlier the edit"
        )
        XCTAssertTrue(store.isAvailable)
        // An opaque selected-span edit must not fall back to replacing all
        // rich text, or leave the previous unrelated operation on Undo.
        store.discard()
        XCTAssertFalse(store.isAvailable)
        let result = await store.undo()
        XCTAssertEqual(result, .failed(reason: "There is no recent verified Bean change to undo."))
    }
}
