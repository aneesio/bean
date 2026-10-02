import AppKit
import Darwin
import Foundation

/// A content-free claim from the browser extension. The token identifies only
/// its current in-memory field session; text, URLs and field labels are absent.
struct BrowserFieldOwnershipRequest: Codable, Equatable, Sendable {
    let fieldToken: String
    let active: Bool
    let observedAtMilliseconds: Double

    func isValid(at now: Date) -> Bool {
        !fieldToken.isEmpty && fieldToken.utf8.count <= 128
            && fieldToken.unicodeScalars.allSatisfy {
                $0.value < 128 && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_")
            }
            && observedAtMilliseconds.isFinite
            && observedAtMilliseconds <= now.timeIntervalSince1970 * 1_000 + 1_000
            && observedAtMilliseconds > now.timeIntervalSince1970 * 1_000 - 5_000
    }
}

struct BrowserFieldOwnershipIdentity: Codable, Equatable, Sendable {
    let processIdentifier: Int32
    let bundleIdentifier: String
    let processStartedAtMicroseconds: UInt64

    @MainActor
    static func current(for app: NSRunningApplication?) -> Self? {
        guard let app, !app.isTerminated, let bundle = app.bundleIdentifier,
              AppCategory.isBrowser(bundle),
              let started = processStartTime(app.processIdentifier) else { return nil }
        return Self(processIdentifier: app.processIdentifier,
                    bundleIdentifier: bundle, processStartedAtMicroseconds: started)
    }

    /// Derive the identity from the browser which actually launched this native
    /// pipe host. A browser PID supplied in JSON is never accepted as evidence.
    @MainActor
    static func nativeHostBrowser() -> Self? {
        var candidate = getppid()
        for _ in 0..<8 {
            guard candidate > 1 else { return nil }
            if let identity = current(for: NSRunningApplication(processIdentifier: candidate)) {
                return identity
            }
            var info = proc_bsdinfo()
            let size = MemoryLayout<proc_bsdinfo>.size
            guard proc_pidinfo(candidate, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == Int32(size),
                  info.pbi_ppid > 1, info.pbi_ppid != UInt32(candidate) else { return nil }
            candidate = Int32(info.pbi_ppid)
        }
        return nil
    }

    private static func processStartTime(_ processIdentifier: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(processIdentifier, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == Int32(size),
              info.pbi_start_tvsec > 0 else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }
}

struct BrowserFieldOwnershipLease: Codable, Equatable {
    let identity: BrowserFieldOwnershipIdentity
    let fieldToken: String
    let active: Bool
    let observedAtMilliseconds: Double
    let expiresAt: Date

    func ownsField(for candidate: BrowserFieldOwnershipIdentity, at now: Date) -> Bool {
        active && identity == candidate && expiresAt > now
            && observedAtMilliseconds.isFinite
            && observedAtMilliseconds > now.timeIntervalSince1970 * 1_000 - 5_000
            && observedAtMilliseconds <= now.timeIntervalSince1970 * 1_000 + 1_000
            && abs(expiresAt.timeIntervalSince1970 - (observedAtMilliseconds / 1_000 + 5)) < 0.001
    }
}

/// Cross-process coordination between the headless native host and Bean's GUI.
/// Per-browser atomic files contain only PID/start-time, an opaque field token
/// and a five-second lease. A missing, expired or unreadable file yields to the
/// native assistant so disabling/crashing the extension cannot remove coverage.
final class BrowserFieldOwnershipStore: @unchecked Sendable {
    private static let maximumLeaseBytes = 4_096
    private let lock: BeanCrossProcessStoreLock
    private let directoryURL: URL

    init(directoryURL: URL = BeanCrossProcessStoreLock.defaultDirectoryURL
        .appendingPathComponent("FieldOwnership", isDirectory: true)) {
        lock = BeanCrossProcessStoreLock(directoryURL: directoryURL)
        self.directoryURL = lock.directoryURL
    }

    @discardableResult
    func record(_ request: BrowserFieldOwnershipRequest,
                for identity: BrowserFieldOwnershipIdentity,
                at now: Date = Date()) -> Bool {
        guard request.isValid(at: now), identity.processIdentifier > 1,
              !identity.bundleIdentifier.isEmpty,
              identity.processStartedAtMicroseconds > 0 else { return false }
        var accepted = false
        let wrote = lock.withExclusiveLock {
            self.pruneExpiredLeases(at: now)
            let previous = self.readLease(for: identity.processIdentifier)
            if let previous, previous.identity == identity {
                // Late callbacks from the previous field must not erase or
                // revive ownership after the extension moved to a new field.
                guard request.observedAtMilliseconds >= previous.observedAtMilliseconds else {
                    return true
                }
                if !request.active, previous.fieldToken != request.fieldToken { return true }
            }
            let lease = BrowserFieldOwnershipLease(
                identity: identity, fieldToken: request.fieldToken, active: request.active,
                observedAtMilliseconds: request.observedAtMilliseconds,
                expiresAt: Date(timeIntervalSince1970: request.observedAtMilliseconds / 1_000 + 5)
            )
            guard let encoded = try? JSONEncoder().encode(lease) else { return false }
            do {
                try ExactFileSystem.writeAtomically(encoded, to: self.fileURL(for: identity.processIdentifier))
                accepted = true
                return true
            } catch { return false }
        }
        return wrote && accepted
    }

    func ownsField(for identity: BrowserFieldOwnershipIdentity,
                   at now: Date = Date()) -> Bool {
        readLease(for: identity.processIdentifier)?.ownsField(for: identity, at: now) ?? false
    }

    @discardableResult
    func removeExpiredLeases(at now: Date = Date()) -> Bool {
        guard (try? ExactFileSystem.entryKind(at: directoryURL)) == .directory else { return true }
        return lock.withExclusiveLock { self.pruneExpiredLeases(at: now); return true }
    }

    private func fileURL(for processIdentifier: Int32) -> URL {
        directoryURL.appendingPathComponent("ownership-\(processIdentifier).json")
    }

    private func readLease(for processIdentifier: Int32) -> BrowserFieldOwnershipLease? {
        guard processIdentifier > 1,
              directoryChainIsReal(),
              let snapshot = try? ExactFileSystem.readRegularFile(
                at: fileURL(for: processIdentifier), maximumBytes: Self.maximumLeaseBytes
              ), snapshot.permissions == 0o600 else { return nil }
        return try? JSONDecoder().decode(BrowserFieldOwnershipLease.self, from: snapshot.data)
    }

    private func directoryChainIsReal() -> Bool {
        // The lock canonicalizes only macOS's trusted /var and /tmp aliases.
        // Do not standardize that immutable path again: Foundation may map an
        // existing /private/tmp path back to the /tmp compatibility symlink.
        var componentURL = URL(fileURLWithPath: "/", isDirectory: true)
        for component in directoryURL.path.split(separator: "/") {
            componentURL.appendPathComponent(String(component), isDirectory: true)
            guard (try? ExactFileSystem.entryKind(at: componentURL)) == .directory else { return false }
        }
        return true
    }

    private func pruneExpiredLeases(at now: Date) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: nil
        ) else { return }
        for file in files.prefix(256) {
            let name = file.lastPathComponent
            guard name.hasPrefix("ownership-"), name.hasSuffix(".json"),
                  let pid = Int32(name.dropFirst(10).dropLast(5)),
                  let lease = readLease(for: pid), lease.expiresAt <= now else { continue }
            try? ExactFileSystem.unlinkRegularFile(at: file)
        }
    }
}
