import Foundation

/// Where notifications go: the serialized stdout writer in production. `onWritten` runs
/// once the line is on the wire; the watcher's buffer accounting depends on it.
protocol NotificationSink: AnyObject {
    func notify(_ line: Data, onWritten: @escaping () -> Void)
}

/// One subscription (design §7.3). `cursor` is the last row examined (emitted, or
/// refused by admission); it never passes a row the wire did not take, nor a row still
/// waiting for its chat join (up to `joinHold`).
final class Subscription {
    var cursor: Int64
    let bufferLimit: Int
    var generation: DBGeneration?
    var overflowed = false
    var lastDelivered: Int64
    var heldRowid: Int64?
    var heldSince: Date?
    private let lock = NSLock()
    private var unwritten = 0

    init(cursor: Int64, bufferLimit: Int, generation: DBGeneration?) {
        self.cursor = cursor
        self.bufferLimit = bufferLimit
        self.generation = generation
        lastDelivered = cursor
    }

    var bufferFull: Bool {
        lock.lock()
        defer { lock.unlock() }
        return unwritten >= bufferLimit
    }

    func enqueued() {
        lock.lock()
        unwritten += 1
        lock.unlock()
    }

    func written() {
        lock.lock()
        unwritten -= 1
        lock.unlock()
    }
}

/// The live inbound path (§7.1, §7.3): kqueue on chat.db, -wal, -shm and the Messages
/// directory plus a poll every `pollInterval` regardless (events are dropped across
/// sleep and the WAL's inode changes on rotation). All state lives on one serial queue.
final class Watcher {
    static let batch = 256
    static let maxBatchesPerTick = 40
    static let watchMask: DispatchSource.FileSystemEvent = [.write, .extend, .delete, .rename, .revoke, .attrib, .link]

    private let location: MessagesLocation
    private let feed: Feed
    private let sink: NotificationSink
    private let log: Logger
    private let now: () -> Date
    private let pollInterval: TimeInterval
    private let joinHold: TimeInterval
    private let queue = DispatchQueue(label: "io.tezra.fermix.messages.watcher")
    private var subscription: Subscription?
    private var databaseAvailable = true
    private var timer: DispatchSourceTimer?
    private var sources: [DispatchSourceFileSystemObject] = []
    private var watchedInodes: [String: UInt64] = [:]

    init(location: MessagesLocation, feed: Feed, sink: NotificationSink, log: Logger, now: @escaping () -> Date,
         pollInterval: TimeInterval = 1, joinHold: TimeInterval = 5) {
        self.location = location
        self.feed = feed
        self.sink = sink
        self.log = log
        self.now = now
        self.pollInterval = pollInterval
        self.joinHold = joinHold
    }

    // MARK: - Requests

    /// One subscription per process; a new one replaces the old. `since_rowid: null`
    /// starts at MAX(ROWID); with `replay` the newest admitted rows after `since_rowid`
    /// that are young enough are replayed (pushed before this returns) and the rest
    /// counted; without `replay` everything after `since_rowid` streams.
    func subscribe(_ params: SubscribeParams) -> Result<SubscribeResult, HelperError> {
        queue.sync { subscribeOnQueue(params) }
    }

    func unsubscribe() {
        queue.sync { subscription = nil }
    }

    func tick() {
        queue.sync { tickOnQueue() }
    }

    func start() {
        queue.sync {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
            timer.setEventHandler { [weak self] in
                self?.tickOnQueue()
                self?.rearmIfMoved()
            }
            timer.resume()
            self.timer = timer
            arm()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            disarm()
        }
    }

    private func subscribeOnQueue(_ params: SubscribeParams) -> Result<SubscribeResult, HelperError> {
        let db: ChatDB
        let stored: StoredPolicy
        switch feed.open() {
        case .success(let opened): (db, stored) = opened
        case .failure(let error): return .failure(error)
        }
        defer { db.close() }
        do {
            let max = try db.maxRowid()
            let fresh = Subscription(cursor: max, bufferLimit: params.bufferLimit,
                                     generation: ChatDB.generation(of: location.chatDB))
            subscription = fresh
            databaseAvailable = true
            var skipped = 0
            if let since = params.sinceRowid, let bounds = params.replay {
                let replay = try replayRows(db, stored, after: since, through: max, bounds: bounds)
                skipped = replay.skipped
                push(replay.rows, to: fresh)
            } else if let since = params.sinceRowid {
                fresh.cursor = since
                fresh.lastDelivered = since
            }
            log.event("subscribed", ["started_at_rowid": String(fresh.cursor), "replay_skipped": String(skipped)])
            return .success(SubscribeResult(startedAtRowid: fresh.cursor, replaySkipped: skipped))
        } catch {
            subscription = nil
            return .failure(.reading(error))
        }
    }

    /// Boot replay (D5): admitted rows in (since, max], at most `max_rows` of the newest
    /// that are younger than `max_age_s`; the rest are counted, never sent.
    private func replayRows(_ db: ChatDB, _ policy: StoredPolicy, after since: Int64, through max: Int64,
                            bounds: ReplayBounds) throws -> (rows: [DecodedRow], skipped: Int) {
        let oldest = now().addingTimeInterval(-Double(bounds.maxAgeS))
        var cursor = since
        var admitted = 0
        var young: [DecodedRow] = []
        while cursor < max {
            let rows = try db.rows(after: cursor, limit: Self.batch)
            guard let last = rows.last?.rowid else { break }
            for raw in rows {
                guard let row = try feed.admit(raw, policy: policy, db: db) else { continue }
                admitted += 1
                if row.date >= oldest { young.append(row) }
            }
            cursor = last
        }
        let replayed = Array(young.suffix(bounds.maxRows))
        return (replayed, admitted - replayed.count)
    }

    // MARK: - Ticks

    private func tickOnQueue() {
        guard let current = subscription, !current.overflowed else { return }
        let generation = ChatDB.generation(of: location.chatDB)
        let db: ChatDB
        switch ChatDB.open(location) {
        case .failure(let failure):
            markUnavailable(failure.helperError.kind.rawValue)
            return
        case .success(let opened):
            db = opened
        }
        defer { db.close() }
        markAvailable()
        if generation != current.generation {
            resetGeneration(current, generation: generation, db: db)
            return
        }
        guard case .success(let stored) = feed.policy.requireConfirmed() else { return }
        do {
            try advance(current, db: db, policy: stored)
        } catch {
            log.event("watch_read_failed", ["error": String(describing: error)])
        }
    }

    private func advance(_ current: Subscription, db: ChatDB, policy: StoredPolicy) throws {
        for _ in 0..<Self.maxBatchesPerTick {
            let rows = try db.rows(after: current.cursor, limit: Self.batch)
            guard let lastVisible = rows.last?.rowid else { return }
            if let pending = try db.firstRowWithoutChat(after: current.cursor, through: lastVisible) {
                try process(rows.filter { $0.rowid < pending }, current, db: db, policy: policy)
                guard !current.overflowed, holdExpired(current, rowid: pending) else { return }
                log.event("row_without_chat_skipped", ["rowid": String(pending)])
                current.cursor = pending
                current.heldRowid = nil
                continue
            }
            try process(rows, current, db: db, policy: policy)
            if current.overflowed || rows.count < Self.batch { return }
        }
    }

    private func process(_ rows: [RawRow], _ current: Subscription, db: ChatDB, policy: StoredPolicy) throws {
        for (offset, raw) in rows.enumerated() {
            guard let row = try feed.admit(raw, policy: policy, db: db) else {
                current.cursor = raw.rowid
                continue
            }
            guard !current.bufferFull else {
                let rest = try rows[offset...].filter { try feed.admit($0, policy: policy, db: db) != nil }
                overflow(current, dropped: rest.count)
                return
            }
            deliver(row, to: current)
        }
    }

    private func push(_ rows: [DecodedRow], to current: Subscription) {
        for (offset, row) in rows.enumerated() {
            guard !current.bufferFull else {
                overflow(current, dropped: rows.count - offset)
                return
            }
            deliver(row, to: current)
        }
    }

    private func deliver(_ row: DecodedRow, to current: Subscription) {
        current.enqueued()
        sink.notify(Wire.encodeNotification(.message, feed.emit(row))) { current.written() }
        current.lastDelivered = Swift.max(current.lastDelivered, row.raw.rowid)
        current.cursor = Swift.max(current.cursor, row.raw.rowid)
    }

    /// The buffer filled: say so once, with the last row on the wire, and stop pushing
    /// until the engine pages with `messages.after` and subscribes again.
    private func overflow(_ current: Subscription, dropped: Int) {
        current.overflowed = true
        let event = OverflowEvent(dropped: dropped, resumeAfterRowid: current.lastDelivered)
        sink.notify(Wire.encodeNotification(.watchOverflow, event)) {}
        log.event("watch_overflow", ["dropped": String(dropped), "resume_after_rowid": String(current.lastDelivered)])
    }

    private func holdExpired(_ current: Subscription, rowid: Int64) -> Bool {
        if current.heldRowid != rowid {
            current.heldRowid = rowid
            current.heldSince = now()
        }
        return now().timeIntervalSince(current.heldSince ?? now()) >= joinHold
    }

    private func resetGeneration(_ current: Subscription, generation: DBGeneration?, db: ChatDB) {
        notifyState(.unavailable, "generation_changed")
        current.generation = generation
        current.heldRowid = nil
        do {
            current.cursor = try db.maxRowid()
        } catch {
            log.event("watch_read_failed", ["error": String(describing: error)])
        }
        current.lastDelivered = current.cursor
        notifyState(.available, nil)
        log.event("generation_changed", ["cursor": String(current.cursor)])
    }

    private func markUnavailable(_ kind: String) {
        guard databaseAvailable else { return }
        databaseAvailable = false
        notifyState(.unavailable, kind)
        log.event("db_unavailable", ["class": kind])
    }

    private func markAvailable() {
        guard !databaseAvailable else { return }
        databaseAvailable = true
        notifyState(.available, nil)
        log.event("db_available")
    }

    private func notifyState(_ state: Availability, _ eventClass: String?) {
        let event = DBStateEvent(state: state, eventClass: eventClass,
                                 dbGeneration: ChatDB.generation(of: location.chatDB))
        sink.notify(Wire.encodeNotification(.dbState, event)) {}
    }

    // MARK: - kqueue

    private var watchedPaths: [String] {
        [location.chatDB, location.chatDB + "-wal", location.chatDB + "-shm", location.directory]
    }

    /// One vnode source per path that can be opened (none can before Full Disk Access is
    /// granted; the poll covers that). Every event ticks and re-arms every source.
    private func arm() {
        watchedInodes = currentInodes()
        for path in watchedPaths {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: Self.watchMask,
                                                                   queue: queue)
            source.setEventHandler { [weak self] in
                self?.tickOnQueue()
                self?.disarm()
                self?.arm()
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
    }

    private func disarm() {
        sources.forEach { $0.cancel() }
        sources = []
    }

    /// Re-arms when a watched file appeared, disappeared or changed inode (WAL rotation,
    /// a replaced database) since the sources were armed.
    private func rearmIfMoved() {
        guard timer != nil, currentInodes() != watchedInodes else { return }
        disarm()
        arm()
    }

    /// stat needs no read permission, so this is accurate before Full Disk Access too.
    private func currentInodes() -> [String: UInt64] {
        var inodes: [String: UInt64] = [:]
        for path in watchedPaths {
            var info = stat()
            if stat(path, &info) == 0 { inodes[path] = UInt64(info.st_ino) }
        }
        return inodes
    }
}
