import Foundation
import Darwin

public final class RunLock {
    private let descriptor: Int32

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var opened = open(url.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        let created = opened >= 0
        if opened < 0 && errno == EEXIST { opened = open(url.path, O_RDWR | O_NOFOLLOW) }
        guard opened >= 0 else { throw BackupError.storage("could not open run lock") }
        var info = stat()
        guard fstat(opened, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            close(opened)
            throw BackupError.invalidConfiguration("run lock must be a regular non-symlink file")
        }
        if created { _ = fchmod(opened, mode_t(S_IRUSR | S_IWUSR)) }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            close(opened)
            throw BackupError.conflict("another sync process is already running")
        }
        descriptor = opened
    }

    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
