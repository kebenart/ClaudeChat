import Foundation
@preconcurrency import SwiftData

/// Factory for the SwiftData `ModelContainer`.
///
/// - `makeOnDisk(profileId:)` creates a per-profile SQLite store under
///   `~/Library/Application Support/ClaudeChat/<profileId>/store.sqlite`.
///   Each server profile (= distinct account) gets its own database so that
///   signing into a different account never shows stale data.
///
/// - `makeInMemory()` creates an ephemeral container used by unit tests.
public enum StorageContainer {

    /// Build the Schema fresh each call — avoids the non-Sendable static-let
    /// issue with Swift 6 strict concurrency while remaining cheap (Schema is
    /// just metadata, not data).
    private static func makeSchema() -> Schema {
        Schema([
            SessionRecord.self, MessageRecord.self,
            ImConversationRecord.self, ImMessageRecord.self,
            ImReadCursorRecord.self, ImSyncStateRecord.self,
        ])
    }

    /// Returns a persistent `ModelContainer` backed by a per-profile SQLite file.
    ///
    /// If the existing store on disk was written with an older schema (e.g.
    /// because the app added a field to `@Model`), the first init attempt
    /// throws. We catch that, wipe the SQLite + WAL + SHM files, and retry
    /// once — preferring "lose data one time on a schema change" over "lose
    /// data on every launch by silently falling back to in-memory".
    public static func makeOnDisk(profileId: UUID) throws -> ModelContainer {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let profileDir = appSupport
            .appendingPathComponent("ClaudeChat", isDirectory: true)
            .appendingPathComponent(profileId.uuidString, isDirectory: true)

        try FileManager.default.createDirectory(
            at: profileDir,
            withIntermediateDirectories: true
        )

        let schema = makeSchema()
        let storeURL = profileDir.appendingPathComponent("store.sqlite")
        let config = ModelConfiguration(schema: schema, url: storeURL)

        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            NSLog("[StorageContainer] makeOnDisk first attempt failed (\(error)). Backing up old store and retrying.")
            // Don't silently lose user data. Move the old store aside with a
            // timestamp suffix so it can be recovered manually if the
            // migration was wrong. SwiftData throws this on schema mismatch
            // (e.g. when we add a non-optional field with default value but
            // the running build doesn't ship a SchemaMigrationPlan).
            let fm = FileManager.default
            let walURL = profileDir.appendingPathComponent("store.sqlite-wal")
            let shmURL = profileDir.appendingPathComponent("store.sqlite-shm")
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let backupBase = profileDir
                .appendingPathComponent("store.sqlite.bak-\(stamp)")
            try? fm.moveItem(at: storeURL,
                             to: backupBase)
            try? fm.moveItem(at: walURL,
                             to: profileDir.appendingPathComponent("store.sqlite-wal.bak-\(stamp)"))
            try? fm.moveItem(at: shmURL,
                             to: profileDir.appendingPathComponent("store.sqlite-shm.bak-\(stamp)"))
            NSLog("[StorageContainer] Old store backed up to \(backupBase.path)")
            return try ModelContainer(for: schema, configurations: [config])
        }
    }

    /// Returns an in-memory `ModelContainer` suitable for unit tests.
    /// Each call creates a completely fresh, isolated store.
    public static func makeInMemory() throws -> ModelContainer {
        let schema = makeSchema()
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }
}
