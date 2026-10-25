import Foundation
import SwiftData

/// Version 1 of the store. When the schema changes, add `JournalSchemaV2` with frozen
/// copies of the old models and a migration stage, so existing journals upgrade cleanly.
public enum JournalSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    public static var models: [any PersistentModel.Type] { [Entry.self, Tag.self, Attachment.self] }
}

public enum JournalMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [JournalSchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}

public enum JournalPersistence {
    public static var schema: Schema { Schema(versionedSchema: JournalSchemaV1.self) }

    /// The on-disk store. CloudKit is explicitly off: sync is our own layer (Phase 3),
    /// because SwiftData's built-in CloudKit sync can't share a store with WebDAV.
    public static func makeContainer(location: StorageLocation) throws -> ModelContainer {
        try location.prepareDirectories()
        let configuration = ModelConfiguration(
            "Journal",
            schema: schema,
            url: location.databaseURL,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, migrationPlan: JournalMigrationPlan.self, configurations: configuration)
    }

    /// An in-memory store for tests and SwiftUI previews.
    public static func makeInMemoryContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "Journal-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, migrationPlan: JournalMigrationPlan.self, configurations: configuration)
    }
}
