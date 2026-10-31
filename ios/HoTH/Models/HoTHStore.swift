import Foundation
import SwiftData

/// Builds the app's SwiftData container.
enum HoTHStore {
    static let modelTypes: [any PersistentModel.Type] = [
        Report.self, Comment.self, Vote.self, Neighbour.self, PointsEvent.self,
    ]

    /// - Parameter inMemory: `true` for previews and tests.
    /// - Throws: the underlying SwiftData error if the store cannot be opened.
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(modelTypes)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
