import Foundation

/// Annotations in `<home>/annotations.json` (formatted like
/// JSON.stringify(list, null, 2)), screenshots in
/// `<home>/images`. Annotations are kept as ordered JSON objects so fields
/// this code doesn't know about survive a save unchanged.
final class Store: @unchecked Sendable {
    static let statuses = ["pending", "acknowledged", "resolved", "dismissed"]

    let home: String
    let file: String
    let images: String

    private let lock = NSLock()
    private var annotations: [JSONObject] = []
    private var version = 0
    private var waiters: [UUID: (CheckedContinuation<Void, Never>, Task<Void, Never>?)] = [:]

    init(home: String) {
        self.home = home
        file = Path.join(home, "annotations.json")
        images = Path.join(home, "images")
        try? FileManager.default.createDirectory(atPath: images, withIntermediateDirectories: true)
        annotations = load()
    }

    private func load() -> [JSONObject] {
        guard FileManager.default.fileExists(atPath: file) else { return [] }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: file))
            let parsed = try JSON.parse(data)
            guard let list = parsed.arrayValue else { throw JSONParseError(description: "expected an array of annotations") }
            return try list.map {
                guard let object = $0.objectValue else { throw JSONParseError(description: "expected an array of annotations") }
                return object
            }
        } catch {
            // Keep the unreadable file for recovery rather than overwriting it on the next save.
            let ms = Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
            let aside = file.hasSuffix(".json") ? String(file.dropLast(5)) + ".corrupt-\(ms).json" : file
            rename(file, aside)
            let message = AppServer.message(error)
            FileHandle.standardError.write(Data("sim-agentation: could not read \(file) (\(message)); moved it to \(aside)\n".utf8))
            return []
        }
    }

    /// Write then rename, so a crash mid-write never leaves a truncated file.
    /// Call with the lock held.
    private func save() throws {
        let tmp = file + ".tmp"
        try JSON.array(annotations.map(JSON.object)).data(indent: 2).write(to: URL(fileURLWithPath: tmp))
        guard rename(tmp, file) == 0 else {
            throw StoreError(description: "could not rename \(tmp): \(String(cString: strerror(errno)))")
        }
        version += 1
        let woken = waiters
        waiters = [:]
        for (continuation, timer) in woken.values {
            timer?.cancel()
            continuation.resume()
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func list(status: String? = nil) -> [JSONObject] {
        locked {
            guard let status, !status.isEmpty else { return annotations }
            return annotations.filter { JS.same($0["status"]?.stringValue, status) }
        }
    }

    /// Pending annotations and the version they were read at, for `waitForChange`.
    func pending() -> (list: [JSONObject], version: Int) {
        locked { (annotations.filter { JS.same($0["status"]?.stringValue, "pending") }, version) }
    }

    /// By full id, or by a prefix of at least 4 characters that matches exactly one annotation.
    func get(_ id: String) -> JSONObject? {
        locked { index(of: id).map { annotations[$0] } }
    }

    private func index(of id: String) -> Int? {
        if let exact = annotations.firstIndex(where: { JS.same($0["id"]?.stringValue, id) }) { return exact }
        if JS.length(id) < 4 { return nil }
        let matches = annotations.indices.filter { annotations[$0]["id"]?.stringValue?.utf8.starts(with: id.utf8) ?? false }
        return matches.count == 1 ? matches[0] : nil
    }

    static func newId() -> String {
        String(UUID().uuidString.lowercased().prefix(8))
    }

    func add(_ annotation: JSONObject) throws -> JSONObject {
        try locked {
            annotations.append(annotation)
            try save()
            return annotation
        }
    }

    /// Like Object.assign(a, patch, { updatedAt }), then the reply appended.
    func update(_ id: String, patch: [(String, JSON)], reply: JSON?) throws -> JSONObject? {
        try locked {
            guard let i = index(of: id) else { return nil }
            var a = annotations[i]
            for (key, value) in patch { a[key] = value }
            a["updatedAt"] = .string(Self.timestamp())
            if let reply { a["replies"] = .array((a["replies"]?.arrayValue ?? []) + [reply]) }
            annotations[i] = a
            try save()
            return a
        }
    }

    /// Deletes one annotation and its screenshots.
    func remove(_ id: String) throws -> Bool {
        let removed: JSONObject? = try locked {
            guard let i = index(of: id) else { return nil }
            let a = annotations.remove(at: i)
            try save()
            return a
        }
        guard let removed else { return false }
        deleteImages(of: removed)
        return true
    }

    func clearFinished() throws {
        let finished: [JSONObject] = try locked {
            let open = { (a: JSONObject) in
                let status = a["status"]?.stringValue
                return JS.same(status, "pending") || JS.same(status, "acknowledged")
            }
            let finished = annotations.filter { !open($0) }
            annotations = annotations.filter(open)
            try save()
            return finished
        }
        for a in finished { deleteImages(of: a) }
    }

    private func deleteImages(of a: JSONObject) {
        for key in ["full", "crop"] {
            if let path = a["images"]?[key]?.stringValue { unlink(path) }
        }
    }

    /// Returns after the next save following `version`, or at the deadline.
    func waitForChange(since version: Int, until deadline: ContinuousClock.Instant) async {
        let id = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if self.version != version {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters[id] = (continuation, nil)
            lock.unlock()
            let timer = Task { [weak self] in
                try? await Task.sleep(until: deadline, tolerance: .milliseconds(5), clock: .continuous)
                guard !Task.isCancelled else { return }
                self?.wake(id)
            }
            lock.lock()
            if waiters[id] != nil { waiters[id]?.1 = timer } else { timer.cancel() }
            lock.unlock()
        }
    }

    private func wake(_ id: UUID) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: id)
        lock.unlock()
        waiter?.0.resume()
    }

    /// new Date().toISOString()
    static func timestamp(_ date: Date = Date()) -> String {
        let totalMs = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
        var seconds = time_t(totalMs / 1000)
        var t = tm()
        gmtime_r(&seconds, &t)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
            t.tm_year + 1900, t.tm_mon + 1, t.tm_mday, t.tm_hour, t.tm_min, t.tm_sec, Int32(totalMs % 1000)
        )
    }
}

struct StoreError: Error, CustomStringConvertible {
    let description: String
}
