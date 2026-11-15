import Foundation
import Testing
@testable import GarageKit

/// `GarageConfig.storeDirectory`: the host can say where the activity store lives
/// (e.g. a folder it keeps out of device backups), and the files land there.
@MainActor
struct GarageStoreLocationTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "GarageStoreLocationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func storeLandsInTheGivenDirectoryAndCreatesIt() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appending(path: "Nested/Garage", directoryHint: .isDirectory)
        let user = UUID(), door = UUID()

        let store = try GarageStore(userID: user, appGroup: nil, directory: dir)
        store.replace(doorID: door, with: [GarageActivity(id: UUID(), doorID: door, kind: .done, at: Date())])

        let file = dir.appending(path: "Garage-\(user.uuidString).store")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(store.all()[door]?.count == 1)
    }

    @Test func reopeningTheSameDirectoryKeepsTheTrail() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let user = UUID(), door = UUID()
        do {
            let store = try GarageStore(userID: user, appGroup: nil, directory: dir)
            store.replace(doorID: door, with: [GarageActivity(id: UUID(), doorID: door, kind: .sent, at: Date())])
        }
        let again = try GarageStore(userID: user, appGroup: nil, directory: dir)
        #expect(again.all()[door]?.first?.kind == .sent)
    }

    @Test func configCarriesTheDirectoryAndDefaultsToNil() {
        let dir = URL(fileURLWithPath: "/tmp/x", isDirectory: true)
        let with = GarageConfig(baseURL: URL(string: "https://example.com")!, currentUserID: UUID(),
                                tokenProvider: { nil }, storeDirectory: dir)
        let without = GarageConfig(baseURL: URL(string: "https://example.com")!, currentUserID: UUID(),
                                   tokenProvider: { nil })
        #expect(with.storeDirectory == dir)
        #expect(without.storeDirectory == nil)
    }
}
