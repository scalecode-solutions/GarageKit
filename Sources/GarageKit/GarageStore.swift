import Foundation
import SwiftData
import os

private let log = Logger(subsystem: "GarageKit", category: "store")

/// The store's versioned schema. Rule: never
/// reshape a shipped @Model in place. To change ActivityRecord later, freeze this
/// definition as a nested @Model inside GarageSchemaV1 (same class name), add
/// GarageSchemaV2 with the live model, and add a MigrationStage — so a schema
/// change migrates instead of failing to open (which would lose the trail).
enum GarageSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [ActivityRecord.self] }
}

enum GarageMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [GarageSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

/// Persisted row of the local activity trail.
@Model
final class ActivityRecord {
    @Attribute(.unique) var id: UUID
    var doorID: UUID
    var kind: String
    var at: Date
    /// Defaulted so existing stores migrate automatically (lightweight).
    var pressAgain: Bool = false

    init(_ a: GarageActivity) {
        id = a.id
        doorID = a.doorID
        kind = a.kind.rawValue
        at = a.at
        pressAgain = a.pressAgain
    }

    var value: GarageActivity {
        GarageActivity(id: id, doorID: doorID, kind: GarageActivity.Kind(rawValue: kind) ?? .failed,
                       at: at, pressAgain: pressAgain)
    }
}

/// The local audit trail of the user's own presses — a cache of the server's
/// record, so history shows instantly (and offline). One SwiftData store per user
/// (`Garage-<uid>.store`), in the host's App Group when given — TraxKit's shape.
/// Never holds pending work: presses are never queued for later.
@MainActor
final class GarageStore {
    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    init(userID: UUID, appGroup: String?, inMemory: Bool = false) throws {
        let schema = Schema(versionedSchema: GarageSchemaV1.self)
        let name = "Garage-\(userID.uuidString)"
        let config: ModelConfiguration
        if inMemory {
            config = ModelConfiguration(name, schema: schema, isStoredInMemoryOnly: true)
        } else if let appGroup,
                  let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            config = ModelConfiguration(name, schema: schema, url: base.appending(path: "\(name).store"))
        } else {
            config = ModelConfiguration(name, schema: schema)
        }
        container = try ModelContainer(for: schema, migrationPlan: GarageMigrationPlan.self,
                                       configurations: config)
    }

    /// Everything cached, grouped by door, newest first.
    func all() -> [UUID: [GarageActivity]] {
        let rows = (try? context.fetch(FetchDescriptor<ActivityRecord>(
            sortBy: [SortDescriptor(\.at, order: .reverse)]))) ?? []
        return Dictionary(grouping: rows.map(\.value), by: \.doorID)
    }

    /// Make a door's cached trail match the server's latest copy: update rows that
    /// changed (e.g. sent → done), insert new ones, delete ones that are gone.
    func replace(doorID: UUID, with fresh: [GarageActivity]) {
        let existing: [ActivityRecord]
        do {
            existing = try context.fetch(FetchDescriptor<ActivityRecord>(
                predicate: #Predicate { $0.doorID == doorID }))
        } catch {
            log.error("fetch trail failed: \(error.localizedDescription)")
            return
        }
        let byID = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for row in existing {
            if let f = byID[row.id] {
                if row.kind != f.kind.rawValue { row.kind = f.kind.rawValue }
                if row.at != f.at { row.at = f.at }
                if row.pressAgain != f.pressAgain { row.pressAgain = f.pressAgain }
            } else {
                context.delete(row)
            }
        }
        let have = Set(existing.map(\.id))
        for a in fresh where !have.contains(a.id) { context.insert(ActivityRecord(a)) }
        save("replace")
    }

    private func save(_ what: String) {
        do { try context.save() } catch { log.error("\(what) save failed: \(error.localizedDescription)") }
    }

    /// Drop the trail for doors the user can no longer see (e.g. a revoked grant).
    func purge(keeping doorIDs: [UUID]) {
        do {
            try context.delete(model: ActivityRecord.self, where: #Predicate { !doorIDs.contains($0.doorID) })
        } catch { log.error("purge failed: \(error.localizedDescription)") }
        save("purge")
    }

    /// Sign-out wipe.
    func wipeAll() {
        do { try context.delete(model: ActivityRecord.self) } catch { log.error("wipe failed: \(error.localizedDescription)") }
        save("wipe")
    }
}
