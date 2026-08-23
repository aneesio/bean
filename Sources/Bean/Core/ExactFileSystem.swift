import Darwin
import Foundation

/// Small POSIX boundary for security-sensitive app-owned files. Foundation's
/// convenience APIs commonly follow symbolic links and `removeItem` may recurse
/// into a directory. These helpers inspect the exact directory entry and use
/// file-descriptor or unlink/rename operations that fail closed instead.
enum ExactFileSystem {
    enum EntryKind: Equatable {
        case missing
        case regularFile
        case directory
        case symbolicLink
        case other
    }

    struct RegularFileSnapshot {
        let data: Data
        let permissions: Int
    }

    static func entryKind(at url: URL) throws -> EntryKind {
        var information = stat()
        let result = url.path.withCString { lstat($0, &information) }
        guard result == 0 else {
            let code = errno
            if code == ENOENT { return .missing }
            throw posixError(code)
        }
        switch information.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFREG):
            // App-owned state and manifests must have one directory entry. A
            // chmod/read through a hard link could otherwise affect or disclose
            // an unrelated sibling inode.
            return information.st_nlink == 1 ? .regularFile : .other
        case mode_t(S_IFDIR): return .directory
        case mode_t(S_IFLNK): return .symbolicLink
        default: return .other
        }
    }

    /// Verifies an existing directory and every descendant component between a
    /// caller-chosen anchor and that directory without resolving symlinks.
    static func requireRealDirectoryChain(from anchor: URL, through directory: URL) throws {
        let root = anchor.standardizedFileURL
        let target = directory.standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard target == root || target.path.hasPrefix(rootPrefix) else {
            throw posixError(EINVAL)
        }
        guard try entryKind(at: root) == .directory else {
            throw posixError(ENOTDIR)
        }
        guard target != root else { return }

        let relative = target.path.dropFirst(rootPrefix.count)
        var current = root
        for component in relative.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: true)
            guard try entryKind(at: current) == .directory else {
                throw posixError(ENOTDIR)
            }
        }
    }

    /// Creates missing descendants one component at a time. Existing symlinks
    /// and non-directories are refused; every resulting directory is mode 0700.
    static func preparePrivateDirectory(_ directory: URL, within anchor: URL) throws {
        let root = anchor.standardizedFileURL
        let target = directory.standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard target == root || target.path.hasPrefix(rootPrefix) else {
            throw posixError(EINVAL)
        }
        guard try entryKind(at: root) == .directory else {
            throw posixError(ENOTDIR)
        }

        var current = root
        if target != root {
            let relative = target.path.dropFirst(rootPrefix.count)
            for component in relative.split(separator: "/") {
                current.appendPathComponent(String(component), isDirectory: true)
                switch try entryKind(at: current) {
                case .missing:
                    let status = current.path.withCString { mkdir($0, mode_t(0o700)) }
                    guard status == 0 else { throw posixError(errno) }
                case .directory:
                    break
                case .regularFile, .symbolicLink, .other:
                    throw posixError(ENOTDIR)
                }
                try enforceDirectoryPermissions(current, permissions: 0o700)
            }
        }
        try enforceDirectoryPermissions(target, permissions: 0o700)
    }

    static func readRegularFile(at url: URL,
                                maximumBytes: Int? = nil) throws -> RegularFileSnapshot {
        let descriptor = url.path.withCString {
            open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw posixError(errno) }
        defer { _ = close(descriptor) }

        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              information.st_nlink == 1 else {
            throw posixError(EINVAL)
        }
        if let maximumBytes {
            guard maximumBytes >= 0,
                  information.st_size >= 0,
                  information.st_size <= off_t(maximumBytes) else {
                throw posixError(EFBIG)
            }
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                read(descriptor, $0.baseAddress, $0.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError(errno)
            }
            if let maximumBytes, data.count + count > maximumBytes {
                throw posixError(EFBIG)
            }
            data.append(buffer, count: count)
        }
        return RegularFileSnapshot(
            data: data,
            permissions: Int(information.st_mode & mode_t(0o777))
        )
    }

    /// Writes through a newly-created 0600 temporary regular file and atomically
    /// renames it over a missing/regular exact target. A pre-existing symlink,
    /// directory, socket, or device is never opened or overwritten.
    static func writeAtomically(_ data: Data, to destination: URL,
                                permissions: Int = 0o600,
                                allowReplacingRegularFile: Bool = true) throws {
        let initialKind = try entryKind(at: destination)
        guard initialKind == .missing
                || (allowReplacingRegularFile && initialKind == .regularFile) else {
            throw posixError(EEXIST)
        }

        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = temporary.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                 mode_t(permissions))
        }
        guard descriptor >= 0 else { throw posixError(errno) }
        var shouldRemoveTemporary = true
        defer {
            _ = close(descriptor)
            if shouldRemoveTemporary {
                temporary.path.withCString { _ = unlink($0) }
            }
        }

        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError(errno)
                }
                guard written > 0 else { throw posixError(EIO) }
                offset += written
            }
        }
        guard fchmod(descriptor, mode_t(permissions)) == 0 else {
            throw posixError(errno)
        }
        guard fsync(descriptor) == 0 else { throw posixError(errno) }

        let currentKind = try entryKind(at: destination)
        guard currentKind == .missing
                || (allowReplacingRegularFile && currentKind == .regularFile) else {
            throw posixError(EEXIST)
        }
        let renameStatus = temporary.path.withCString { source in
            destination.path.withCString { target in rename(source, target) }
        }
        guard renameStatus == 0 else { throw posixError(errno) }
        shouldRemoveTemporary = false
        guard try entryKind(at: destination) == .regularFile else {
            throw posixError(EIO)
        }
    }

    static func enforceRegularFilePermissions(_ url: URL, permissions: Int) throws {
        let descriptor = url.path.withCString {
            open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw posixError(errno) }
        defer { _ = close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              information.st_nlink == 1,
              fchmod(descriptor, mode_t(permissions)) == 0 else {
            throw posixError(errno == 0 ? EINVAL : errno)
        }
    }

    /// `unlink` cannot recursively delete a directory. A race that swaps a
    /// regular target for a symlink can at worst unlink that link, never its
    /// external referent.
    static func unlinkRegularFile(at url: URL) throws {
        guard try entryKind(at: url) == .regularFile else {
            throw posixError(EINVAL)
        }
        let status = url.path.withCString { unlink($0) }
        guard status == 0, try entryKind(at: url) == .missing else {
            throw posixError(errno == 0 ? EIO : errno)
        }
    }

    static func removeEmptyDirectory(at url: URL) throws {
        guard try entryKind(at: url) == .directory else {
            throw posixError(ENOTDIR)
        }
        let status = url.path.withCString { rmdir($0) }
        guard status == 0 else { throw posixError(errno) }
    }

    private static func enforceDirectoryPermissions(_ url: URL, permissions: Int) throws {
        let descriptor = url.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw posixError(errno) }
        defer { _ = close(descriptor) }
        guard fchmod(descriptor, mode_t(permissions)) == 0 else {
            throw posixError(errno)
        }
    }

    private static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
