import SwiftData
import XCTest
@testable import HoTH

/// Settings "Reset app": store wiped and re-seeded, `hoth.` defaults cleared, app files removed,
/// notifications cancelled, API key removed only on request. In-memory store, isolated defaults suite,
/// temp directories and stubbed side effects (no Keychain, no notification center).
@MainActor
final class AppResetterTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var documents: URL!
    private var temporary: URL!
    private var cancelCount = 0
    private var deleteKeyCount = 0
    private var keyError: Error?

    private struct KeychainFailure: Error {}

    override func setUp() async throws {
        container = try HoTHStore.makeContainer(inMemory: true)
        context = container.mainContext
        suiteName = "AppResetterTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppResetterTests-\(UUID().uuidString)")
        documents = root.appendingPathComponent("Documents")
        temporary = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        cancelCount = 0
        deleteKeyCount = 0
        keyError = nil
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: documents.deletingLastPathComponent())
    }

    private func makeResetter() -> AppResetter {
        AppResetter(
            defaults: defaults,
            bundle: Bundle(for: AppServices.self),
            documentsDirectory: documents,
            temporaryDirectory: temporary,
            cancelNotifications: { [unowned self] in cancelCount += 1 },
            deleteAPIKey: { [unowned self] in
                deleteKeyCount += 1
                if let keyError { throw keyError }
            }
        )
    }

    private func write(_ name: String, in directory: URL) throws {
        try Data("x".utf8).write(to: directory.appendingPathComponent(name))
    }

    private func fileNames(in directory: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }

    // MARK: Store

    func testResetRemovesUserContentAndReseedsLikeFirstLaunch() throws {
        try SeedLoader.seedIfNeeded(context: context, defaults: defaults, bundle: Bundle(for: AppServices.self))
        let seededReports = try context.fetchCount(FetchDescriptor<Report>())
        let seededNeighbours = try context.fetchCount(FetchDescriptor<Neighbour>())

        let me = try XCTUnwrap(try context.fetch(FetchDescriptor<Neighbour>(predicate: #Predicate { $0.isCurrentUser })).first)
        let seededPoints = me.points
        let mine = Report(createdAt: .now, category: .potholePavement, titleEN: "Mine", titleAR: "لي",
                          summaryEN: "", summaryAR: "", latitude: 24.42, longitude: 54.57, placeName: "Street 1",
                          priority: .low, priorityScore: 10, priorityReasonEN: "", priorityReasonAR: "",
                          status: .open, reporter: me)
        context.insert(mine)
        me.points += 500
        try context.save()

        try makeResetter().reset(context: context)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Report>()), seededReports)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Neighbour>()), seededNeighbours)
        let reports = try context.fetch(FetchDescriptor<Report>())
        XCTAssertTrue(reports.allSatisfy(\.isDemoSeed), "User reports must be gone")
        let currentUsers = try context.fetch(FetchDescriptor<Neighbour>(predicate: #Predicate { $0.isCurrentUser }))
        XCTAssertEqual(currentUsers.count, 1, "Exactly one current user after reset")
        XCTAssertEqual(currentUsers[0].points, seededPoints, "Points back to the seeded value")
        XCTAssertTrue(defaults.bool(forKey: SeedLoader.seededFlagKey))
    }

    // MARK: Defaults

    func testResetClearsAppDefaultsAndKeepsOthers() throws {
        defaults.set(true, forKey: OnboardingView.storageKey)
        defaults.set(false, forKey: AppServices.SettingsKey.demoMode)
        defaults.set("crew", forKey: AppServices.SettingsKey.role)
        defaults.set("ar", forKey: AppServices.SettingsKey.language)
        defaults.set("custom-model", forKey: AppServices.SettingsKey.visionModel)
        defaults.set("a,b", forKey: ConfirmedReports.storageKey)
        defaults.set(true, forKey: NeighbourAlertCenter.StorageKey.demoSimulated)
        defaults.set("kept", forKey: "com.example.other")

        try makeResetter().reset(context: context)

        for key in [OnboardingView.storageKey, AppServices.SettingsKey.demoMode, AppServices.SettingsKey.role,
                    AppServices.SettingsKey.language, AppServices.SettingsKey.visionModel,
                    ConfirmedReports.storageKey, NeighbourAlertCenter.StorageKey.demoSimulated] {
            XCTAssertNil(defaults.object(forKey: key), "\(key) should be cleared")
        }
        XCTAssertEqual(defaults.string(forKey: "com.example.other"), "kept")
    }

    // MARK: Files

    func testResetDeletesPhotosAndVoiceTempFilesOnly() throws {
        try write("report_1.jpg", in: documents)
        try write("fix_2.JPG", in: documents)
        try write("notes.txt", in: documents)
        try write("hoth-ptt-1.wav", in: temporary)
        try write("other.tmp", in: temporary)

        let outcome = try makeResetter().reset(context: context)

        XCTAssertEqual(outcome.removedFileCount, 3)
        XCTAssertEqual(try fileNames(in: documents), ["notes.txt"])
        XCTAssertEqual(try fileNames(in: temporary), ["other.tmp"])
    }

    func testMissingDirectoriesAreNotAnError() throws {
        var resetter = makeResetter()
        resetter.documentsDirectory = nil
        resetter.temporaryDirectory = documents.appendingPathComponent("does-not-exist")
        XCTAssertEqual(try resetter.reset(context: context).removedFileCount, 0)
    }

    func testMissingSeedThrowsBeforeChangingAnything() throws {
        try SeedLoader.seedIfNeeded(context: context, defaults: defaults, bundle: Bundle(for: AppServices.self))
        let reportCount = try context.fetchCount(FetchDescriptor<Report>())
        defaults.set(true, forKey: OnboardingView.storageKey)
        try write("report_1.jpg", in: documents)
        var resetter = makeResetter()
        resetter.bundle = Bundle(for: AppResetterTests.self)  // test bundle: no seed.json

        XCTAssertThrowsError(try resetter.reset(context: context))

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Report>()), reportCount)
        XCTAssertEqual(defaults.object(forKey: OnboardingView.storageKey) as? Bool, true)
        XCTAssertEqual(try fileNames(in: documents), ["report_1.jpg"])
        XCTAssertEqual(cancelCount, 0)
    }

    // MARK: Notifications & key

    func testResetCancelsNotificationsAndKeepsKeyByDefault() throws {
        let outcome = try makeResetter().reset(context: context)
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(deleteKeyCount, 0)
        XCTAssertFalse(outcome.removedAPIKey)
        XCTAssertFalse(outcome.failedToRemoveAPIKey)
    }

    func testResetRemovesKeyWhenAsked() throws {
        let outcome = try makeResetter().reset(context: context, removingAPIKey: true)
        XCTAssertEqual(deleteKeyCount, 1)
        XCTAssertTrue(outcome.removedAPIKey)
    }

    func testKeyRemovalFailureStillResetsEverythingElse() throws {
        keyError = KeychainFailure()
        defaults.set(true, forKey: OnboardingView.storageKey)
        try write("report_1.jpg", in: documents)

        let outcome = try makeResetter().reset(context: context, removingAPIKey: true)

        XCTAssertFalse(outcome.removedAPIKey)
        XCTAssertTrue(outcome.failedToRemoveAPIKey)
        XCTAssertNil(defaults.object(forKey: OnboardingView.storageKey))
        XCTAssertEqual(outcome.removedFileCount, 1)
        XCTAssertEqual(cancelCount, 1)
    }
}
