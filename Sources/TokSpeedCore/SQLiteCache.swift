import Foundation

struct LocalFileStamp: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int

    init?(_ path: String) {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanos = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec
        changedNanos = info.st_ctimespec.tv_nsec
    }
}

// A writer can reuse a preallocated WAL without changing either file's size.
struct SQLiteDatabaseStamp: Equatable {
    private let database: LocalFileStamp
    private let wal: LocalFileStamp?

    var lastWrite: Date {
        func modified(_ file: LocalFileStamp) -> Date {
            Date(timeIntervalSince1970: Double(file.modifiedSeconds) + Double(file.modifiedNanos) / 1e9)
        }
        // Opening a read-only SQLite handle can create an empty WAL. Only
        // count a WAL with frames as evidence for which databases to inspect.
        return max(modified(database), wal.flatMap { $0.size > 32 ? modified($0) : nil } ?? .distantPast)
    }

    init?(_ path: String) {
        guard let database = LocalFileStamp(path) else { return nil }
        self.database = database
        wal = LocalFileStamp(path + "-wal")
    }
}

struct SQLiteDatabaseCache<Value> {
    private var entry: (stamp: SQLiteDatabaseStamp, value: Value)?

    mutating func invalidate() {
        entry = nil
    }

    mutating func read(_ path: String, load: (String) -> Value?) -> Value? {
        let before = SQLiteDatabaseStamp(path)
        if let entry, entry.stamp == before { return entry.value }
        entry = nil
        guard let before, let value = load(path) else { return nil }
        // If a writer raced the read, revisit it next tick rather than caching
        // a snapshot under the newer stamp. Failed reads are also retried.
        if before == SQLiteDatabaseStamp(path) { entry = (before, value) }
        return value
    }
}
