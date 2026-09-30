import Foundation

/// Where the sync gets QuickBooks data from. The gateway's implementation
/// goes through the company's own upstream process (the only holder of its
/// token); tests use a fake.
public protocol QBOFetcher: Sendable {
    /// Runs a QBO query statement; returns Intuit's JSON response.
    func query(_ statement: String) async throws -> JSON
    /// Intuit's Change Data Capture since a timestamp.
    func changeDataCapture(entities: [String], since: String) async throws -> JSON
}

public enum QBOFetchError: Error, CustomStringConvertible {
    /// The refresh token is dead; nothing will work until a reconnect.
    case needsAuth(String)
    case failed(String)

    public var description: String {
        switch self {
        case .needsAuth(let message), .failed(let message): message
        }
    }
}

/// Incremental sync of one company into its cache.
///
/// Per entity type: fetch `MetaData.LastUpdatedTime >= watermark` in pages
/// ordered by that time, upsert each page, and advance the watermark only
/// once the page is committed — so an interrupted run resumes where it
/// stopped and re-reads at most one page. `>=` rather than `>` because many
/// rows can share a timestamp; upserts make the overlap harmless.
///
/// The query API never returns deleted rows, so each run also reads Intuit's
/// Change Data Capture feed and marks those. CDC reaches back 30 days; a
/// cache left unsynced for longer needs a rebuild to catch older deletes,
/// which `cache_status` reports.
public enum QBOCacheSync {
    public static let cdcKey = "__cdc"
    static let pageSize = 1000
    static let cdcWindow: TimeInterval = 29 * 86400

    public struct Result: Sendable {
        public var status: String  // ok | needs_auth | error
        public var rows = 0
        public var deleted = 0
        public var error: String?
        public var entityErrors: [String: String] = [:]
        public var started = Date()
        public var finished = Date()

        public var json: JSON {
            [
                "status": .string(status),
                "started_at": .string(parser.string(from: started)),
                "finished_at": .string(parser.string(from: finished)),
                "rows_upserted": .number(Double(rows)),
                "rows_deleted": .number(Double(deleted)),
                "entity_errors": .object(entityErrors.mapValues { .string($0) }),
                "error": error.map { .string($0) } ?? .null,
            ]
        }
    }

    // ISO8601DateFormatter is thread-safe.
    nonisolated(unsafe) private static let parser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(_ text: String) -> Date? {
        parser.date(from: text) ?? {
            // QBO sometimes includes fractional seconds.
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: text)
        }()
    }

    /// The latest LastUpdatedTime in a page, compared as instants: offsets
    /// change with daylight saving, so string order isn't time order.
    static func latest(_ objects: [JSON]) -> String? {
        objects.compactMap { $0["MetaData"]?["LastUpdatedTime"]?.stringValue }
            .max { (date($0) ?? .distantPast) < (date($1) ?? .distantPast) }
    }

    /// `only` limits the query pass to some entity types; deletions are
    /// always checked, since the change feed covers everything in one call.
    public static func run(store: QBOCacheStore, fetcher: QBOFetcher, log: FileLog, only: Set<String>? = nil) async -> Result {
        let started = Date()
        var result = Result(status: "ok", started: started)
        let slug = store.slug
        do {
            for (entity, kind) in QBOCacheStore.entityTypes where only?.contains(entity) ?? true {
                do {
                    let rows = try await syncEntity(entity, kind: kind, store: store, fetcher: fetcher)
                    result.rows += rows
                    try await store.recordEntityRun(entity, rows: rows, error: nil)
                } catch let error as QBOFetchError {
                    if case .needsAuth = error { throw error }
                    // One entity failing (say, a feature the company lacks)
                    // shouldn't stop the rest.
                    try? await store.recordEntityRun(entity, rows: 0, error: error.description)
                    result.error = "\(entity): \(error.description)"
                    result.entityErrors[entity] = error.description
                    log.write("[\(slug)] [cache] \(entity) failed: \(error.description)")
                }
            }
            result.deleted = try await syncDeletions(store: store, fetcher: fetcher, log: log)
            if result.error != nil { result.status = "error" }
        } catch QBOFetchError.needsAuth(let message) {
            result.status = "needs_auth"
            result.error = message
        } catch {
            result.status = "error"
            result.error = "\(error)"
        }
        result.finished = Date()
        try? await store.recordRun(started: started, status: result.status, rows: result.rows,
                                   deleted: result.deleted, error: result.error)
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        log.write("[\(slug)] [cache] \(result.status): \(result.rows) rows, \(result.deleted) deleted in \(seconds)s"
                  + (result.error.map { " — \($0)" } ?? ""))
        return result
    }

    /// How a query is phrased. QuickBooks rejects some combinations for some
    /// entities with an unhelpful "internal error", so a failing first page is
    /// retried in simpler forms before the entity counts as failed.
    struct Phrasing {
        var ordered: Bool
        var activeFilter: Bool
    }

    static func statement(_ entity: String, watermark: String?, _ phrasing: Phrasing, position: Int) -> String {
        var conditions: [String] = []
        // No watermark means a first, full sync: no date filter at all. A
        // sentinel like 1900-01-01 makes QuickBooks fail the whole query.
        if let watermark { conditions.append("MetaData.LastUpdatedTime >= '\(watermark)'") }
        // Name lists hide inactive records unless asked for both.
        if phrasing.activeFilter { conditions.append("Active IN (true, false)") }
        let filter = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
        let order = phrasing.ordered ? " ORDERBY MetaData.LastUpdatedTime" : ""
        return "SELECT * FROM \(entity)\(filter)\(order) STARTPOSITION \(position) MAXRESULTS \(pageSize)"
    }

    /// How far behind "now" a successful sync may safely claim to be current:
    /// a margin for clock differences between this Mac and Intuit.
    static let settleMargin: TimeInterval = 300

    static func syncEntity(_ entity: String, kind: QBOCacheStore.Kind, store: QBOCacheStore, fetcher: QBOFetcher) async throws -> Int {
        let started = Date()
        let watermark = try await store.watermark(entity)
        var isList = false
        if case .list = kind { isList = true }
        // Preferred first; each fallback drops one refinement.
        var phrasings = [Phrasing(ordered: true, activeFilter: isList), Phrasing(ordered: false, activeFilter: isList)]
        if isList { phrasings.append(Phrasing(ordered: false, activeFilter: false)) }
        var phrasing = phrasings.removeFirst()
        var position = 1
        var total = 0
        var newest: String?
        while true {
            let response: JSON
            do {
                response = try await fetcher.query(statement(entity, watermark: watermark, phrasing, position: position))
            } catch QBOFetchError.failed(let message) where position == 1 && !phrasings.isEmpty {
                // Only the first page falls back, so every page of a run
                // uses the same phrasing and the paging stays consistent.
                _ = message
                phrasing = phrasings.removeFirst()
                continue
            }
            let objects = response["QueryResponse"]?[entity]?.arrayValue ?? []
            let pageNewest = latest(objects)
            total += try await store.ingest(entity: entity, objects: objects, watermark: phrasing.ordered ? pageNewest : nil)
            if let pageNewest, (date(pageNewest) ?? .distantPast) > (newest.flatMap(date) ?? .distantPast) {
                newest = pageNewest
            }
            if objects.count < pageSize { break }
            position += pageSize
        }
        // Unordered pages are complete, but the watermark may only move once
        // all of them are in.
        if !phrasing.ordered, let newest { try await store.setWatermark(entity, newest) }
        // Everything changed before the run started has now been read, so the
        // watermark can move up to then even when nothing changed. That keeps
        // quiet or empty entity types from looking stale in cache_status.
        let settled = started.addingTimeInterval(-settleMargin)
        let current = try await store.watermark(entity).flatMap(date) ?? .distantPast
        if settled > current { try await store.setWatermark(entity, parser.string(from: settled)) }
        return total
    }

    static func syncDeletions(store: QBOCacheStore, fetcher: QBOFetcher, log: FileLog) async throws -> Int {
        let callTime = Date()
        let floor = callTime.addingTimeInterval(-cdcWindow)
        var since = try await store.watermark(cdcKey).flatMap(date) ?? floor
        if since < floor {
            log.write("[\(store.slug)] [cache] CDC watermark is older than Intuit's 30-day window; deletes before \(parser.string(from: floor)) aren't visible without a rebuild")
            since = floor
        }
        let names = QBOCacheStore.entityTypes.map(\.name)
        let response = try await fetcher.changeDataCapture(entities: names, since: parser.string(from: since))

        var deletedByEntity: [String: [String]] = [:]
        var updatedByEntity: [String: [JSON]] = [:]
        for block in response["CDCResponse"]?.arrayValue ?? [] {
            for queryResponse in block["QueryResponse"]?.arrayValue ?? [] {
                for (entity, value) in queryResponse.objectValue ?? [:] {
                    for object in value.arrayValue ?? [] {
                        guard let id = object["Id"]?.stringValue else { continue }
                        if object["status"]?.stringValue == "Deleted" {
                            deletedByEntity[entity, default: []].append(id)
                        } else {
                            updatedByEntity[entity, default: []].append(object)
                        }
                    }
                }
            }
        }
        var deleted = 0
        for (entity, ids) in deletedByEntity {
            deleted += try await store.markDeleted(entity: entity, ids: ids)
        }
        // Changes CDC sees are applied too: harmless duplicates of what the
        // query pass fetched, and they close any gap between the two calls.
        for (entity, objects) in updatedByEntity {
            _ = try await store.ingest(entity: entity, objects: objects, watermark: nil)
        }
        // A minute of overlap covers clock skew between here and Intuit.
        try await store.setWatermark(cdcKey, parser.string(from: callTime.addingTimeInterval(-60)))
        return deleted
    }
}
