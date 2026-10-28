import AppKit
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

/// Fork Phase 1: Library Trash is deleted permanently after 30 days or by
/// Empty Trash. Synthetic temp folders and an injected clock only.
@MainActor final class TrashPurgeTests: HistoryTestCase {
    private let day: TimeInterval = 86400
    private func fixture() throws -> SyntheticFixture {
        let value = try SyntheticFixture(); value.date = Date(timeIntervalSince1970: 1_700_000_000); return value
    }
    private func store(_ f: SyntheticFixture) throws -> LibraryStore {
        try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date }, moveToTrash: fixtureTrash(f.folder))
    }
    /// Moves the clock back, trashes, and restores the clock.
    private func trash(_ ids: [UUID], daysAgo: Double, _ f: SyntheticFixture, _ library: LibraryStore) throws {
        let now = f.date; f.date = now.addingTimeInterval(-daysAgo * day); defer { f.date = now }
        try library.trashUndoably(ids)
    }
    private func count(_ db: LibraryDatabase, _ sql: String, _ id: UUID) throws -> Int64 {
        try db.rows(sql, [.text(id.uuidString)]).first?["n"]?.number ?? -1
    }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func testAutomaticPurgeDeletesOnlyTrashOlderThanThirtyDays() throws {
        let f = try fixture(); defer { f.cleanup() }; let library = try store(f)
        let old = try XCTUnwrap(library.captureText("Trashed 31 days ago")), recent = try XCTUnwrap(library.captureText("Trashed 29 days ago"))
        let saved = try XCTUnwrap(library.captureText("Saved, then trashed")), live = try XCTUnwrap(library.captureText("Never trashed"))
        let link = try library.captureLink(try XCTUnwrap(URL(string: "https://example.com/old-trash")))
        try library.retain([saved.id])
        try trash([old.id, saved.id, link.id], daysAgo: 31, f, library); try trash([recent.id], daysAgo: 29, f, library)
        let revision = library.revision
        XCTAssertEqual(Set(try library.purgeExpiredTrash()), Set([old.id, saved.id, link.id]))
        XCTAssertEqual(library.revision, revision + 1)
        for id in [old.id, saved.id, link.id] { XCTAssertNil(try library.item(id)) }
        XCTAssertNotNil(try library.item(recent.id)?.deletedAt)
        XCTAssertNil(try library.item(live.id)?.deletedAt)
        XCTAssertEqual(try library.purgeExpiredTrash(), [])
        XCTAssertEqual(library.revision, revision + 1, "A purge that deletes nothing publishes nothing")
        f.date = f.date.addingTimeInterval(2 * day)
        XCTAssertEqual(try library.purgeExpiredTrash(), [recent.id])
        XCTAssertNotNil(try library.item(live.id))
    }

    func testPurgeRemovesEveryDependentRow() throws {
        let f = try fixture(); defer { f.cleanup() }; let library = try store(f)
        let text = try XCTUnwrap(library.captureText("Dependent rows text")), image = try library.captureImage(try f.image())
        let folder = try library.createCollection("Purged folder")
        try library.assign([text.id, image.id], to: folder); try library.addTag("purged", to: [text.id, image.id])
        let db = try LibraryDatabase(url: library.databaseURL)
        try db.execute("INSERT INTO image_analysis VALUES(?,?,?,?,?,?,?)", [.text(image.id.uuidString), .text(try XCTUnwrap(image.path)),
            .text("fingerprint"), .text("v1"), .text("ocr secret"), .text("OCR secret"), .blob(Data([1, 2, 3]))])
        try db.execute("INSERT INTO image_markup_garbage VALUES(?)", [.text(try XCTUnwrap(image.path))])
        for id in [text.id, image.id] {
            XCTAssertEqual(try count(db, "SELECT count(*) AS n FROM search_fts WHERE id=?", id), 1)
            XCTAssertEqual(try count(db, "SELECT count(*) AS n FROM item_collections WHERE item=?", id), 1)
            XCTAssertEqual(try count(db, "SELECT count(*) AS n FROM item_tags WHERE item=?", id), 1)
        }
        XCTAssertEqual(try count(db, "SELECT count(*) AS n FROM text_identity WHERE item=?", text.id), 1)
        XCTAssertEqual(try count(db, "SELECT count(*) AS n FROM image_analysis WHERE item=?", image.id), 1)
        try library.trashUndoably([text.id, image.id])
        XCTAssertEqual(Set(try library.emptyTrash(try library.trashSnapshot())), Set([text.id, image.id]))
        for id in [text.id, image.id] {
            for table in ["items WHERE id=?", "search_fts WHERE id=?", "item_collections WHERE item=?", "item_tags WHERE item=?", "text_identity WHERE item=?", "image_analysis WHERE item=?"] {
                XCTAssertEqual(try count(db, "SELECT count(*) AS n FROM " + table, id), 0, table)
            }
        }
        XCTAssertTrue(try db.rows("SELECT path FROM image_markup_garbage").isEmpty)
        XCTAssertTrue(try db.rows("SELECT path FROM purged_files").isEmpty)
        // Organization itself stays; only the memberships are removed.
        XCTAssertEqual(try library.collections().map(\.id), [folder]); XCTAssertEqual(try library.tags().map(\.name), ["purged"])
        XCTAssertTrue(try library.query(LibraryQuery(scope: .saved, search: "dependent")).isEmpty)
    }

    func testPurgeDeletesManagedFilesFromDiskAndNeverExternalOriginals() throws {
        let f = try fixture(); defer { f.cleanup() }; let library = try store(f)
        let clipboardPNG = try f.image(), clipboard = try library.captureImage(clipboardPNG)
        let external = try f.image(owned: false), externalBytes = try Data(contentsOf: external)
        let externalItem = try library.captureImage(external)
        let pinnedSource = try f.image(owned: false), pinned = try library.captureImage(pinnedSource)
        try library.pin([pinned.id])
        let pinnedCopy = try XCTUnwrap(library.item(pinned.id)?.fileURL)
        XCTAssertTrue(library.files.isFavoriteCopy(pinnedCopy))
        let markupSource = try f.image(owned: false), marked = try library.captureImage(markupSource)
        let edited = try library.saveImageMarkup(marked.id, document: ImageMarkupDocument(elements: [ImageMarkupElement(tool: .rectangle,
            points: [MarkupPoint(x: 0.2, y: 0.2), MarkupPoint(x: 0.8, y: 0.8)], color: .red, lineWidth: 0.05, fill: true)]))
        let rendered = try XCTUnwrap(edited.fileURL), base = URL(fileURLWithPath: try XCTUnwrap(edited.markupBasePath))
        XCTAssertTrue(library.files.isFavoriteCopy(rendered)); XCTAssertTrue(library.files.isFavoriteCopy(base))
        let text = try XCTUnwrap(library.captureText("Materialized secret text"))
        let textFile = try LibraryTransfer.materialize(text, store: library)
        let link = try library.captureLink(try XCTUnwrap(URL(string: "https://example.com/thumbnail")))
        let linkFile = try LibraryTransfer.materialize(link, store: library)
        try FileManager.default.createDirectory(at: library.thumbnailsFolder, withIntermediateDirectories: true)
        let thumbnail = library.thumbnailsFolder.appendingPathComponent("\(link.id)-\(UUID()).image"), orphan = library.thumbnailsFolder.appendingPathComponent("\(link.id)-\(UUID()).image")
        let otherThumbnail = library.thumbnailsFolder.appendingPathComponent("\(UUID())-\(UUID()).image")
        for file in [thumbnail, orphan, otherThumbnail] { try Data([9]).write(to: file) }
        try library.update(link.id) { $0.thumbnailPath = thumbnail.path }
        // A symlink where a materialized copy would be is never followed.
        let outside = f.folder.appendingPathComponent("Outside.txt"); try Data("outside".utf8).write(to: outside)
        let linked = try XCTUnwrap(library.captureText("Symlinked materialized text"))
        let symlink = textFile.deletingLastPathComponent().appendingPathComponent("Text \(linked.id).txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        let ids = [clipboard.id, externalItem.id, pinned.id, marked.id, text.id, link.id, linked.id]
        try library.trashUndoably(ids)
        let managed = [clipboardPNG, pinnedCopy, rendered, base, textFile, linkFile, thumbnail, orphan]
        for file in managed { XCTAssertTrue(exists(file), file.path) }
        XCTAssertEqual(Set(try library.emptyTrash(try library.trashSnapshot())), Set(ids))
        for file in managed { XCTAssertFalse(exists(file), file.path) }
        for file in [external, pinnedSource, markupSource, otherThumbnail, outside] { XCTAssertTrue(exists(file), file.path) }
        XCTAssertEqual(try Data(contentsOf: external), externalBytes)
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
        // Removed from disk, not moved to the (injected) system Trash.
        let fixtureTrashFolder = f.folder.appendingPathComponent(".test-trash")
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: fixtureTrashFolder.path)) ?? []).isEmpty)
    }

    func testSharedManagedPathIsKeptWhileALiveItemStillUsesIt() throws {
        let f = try fixture(); defer { f.cleanup() }; let library = try store(f)
        let file = try f.image(), first = try library.captureImage(file)
        try library.trash([first.id])
        let second = try library.captureImage(file)
        XCTAssertNotEqual(first.id, second.id); XCTAssertEqual(second.path, first.path)
        XCTAssertEqual(try library.emptyTrash([first.id]), [first.id])
        XCTAssertTrue(exists(file)); XCTAssertEqual(try library.item(second.id)?.path, file.standardizedFileURL.path)
        XCTAssertTrue(try LibraryDatabase(url: library.databaseURL).rows("SELECT path FROM purged_files").isEmpty)
        try library.trash([second.id]); XCTAssertEqual(try library.emptyTrash([second.id]), [second.id])
        XCTAssertFalse(exists(file))
    }

    func testProtectedItemsSurviveAutomaticPurgeButEmptyTrashDeletesThem() throws {
        let f = try fixture(); defer { f.cleanup() }; let library = try store(f)
        let pinned = try XCTUnwrap(library.captureText("Pinned then removed")), foldered = try XCTUnwrap(library.captureText("Foldered then removed"))
        let tagged = try XCTUnwrap(library.captureText("Tagged then removed")), plain = try XCTUnwrap(library.captureText("Plain removal"))
        try library.toggleFavorite([pinned.id])
        let folder = try library.createCollection("Kept folder"); try library.assign([foldered.id], to: folder)
        try library.addTag("kept", to: [tagged.id])
        // Explicit Library removal keeps pin, folder and tag: protected rows can sit in Trash.
        try trash([pinned.id, foldered.id, tagged.id, plain.id], daysAgo: 45, f, library)
        XCTAssertEqual(try library.item(pinned.id)?.favorite, true)
        XCTAssertEqual(try library.collections(for: foldered.id).map(\.id), [folder])
        XCTAssertEqual(try library.tags(for: tagged.id).map(\.name), ["kept"])
        XCTAssertEqual(try library.purgeExpiredTrash(), [plain.id])
        f.date = f.date.addingTimeInterval(1000 * day)
        XCTAssertEqual(try library.purgeExpiredTrash(), [])
        let snapshot = try library.trashSnapshot()
        XCTAssertEqual(Set(snapshot), Set([pinned.id, foldered.id, tagged.id]))
        XCTAssertEqual(Set(try library.emptyTrash(snapshot)), Set(snapshot))
        for id in snapshot { XCTAssertNil(try library.item(id)) }
        XCTAssertTrue(try library.trashSnapshot().isEmpty)
    }

    func testEmptyTrashDeletesOnlyTheConfirmedItemsStillInTrash() throws {
        let f = try fixture(); defer { f.cleanup() }; let library = try store(f)
        let a = try XCTUnwrap(library.captureText("Confirmed A")), b = try XCTUnwrap(library.captureText("Restored before confirm"))
        let c = try XCTUnwrap(library.captureText("Trashed after the dialog opened"))
        try library.trashUndoably([a.id, b.id])
        let snapshot = try library.trashSnapshot(); XCTAssertEqual(snapshot.count, 2)
        try library.restore([b.id]); try library.trash([c.id])
        XCTAssertEqual(try library.emptyTrash(snapshot), [a.id])
        XCTAssertNil(try library.item(a.id)); XCTAssertNil(try library.item(b.id)?.deletedAt)
        XCTAssertNotNil(try library.item(c.id)?.deletedAt)
        XCTAssertEqual(try library.emptyTrash([]), [])
    }

    func testUndoJournalsNeverRestoreAPurgedItem() throws {
        let f = try fixture(); defer { f.cleanup() }; let library = try store(f)
        let a = try XCTUnwrap(library.captureText("Undo A")), b = try XCTUnwrap(library.captureText("Undo B"))
        try library.trashUndoably([a.id, b.id]); XCTAssertTrue(library.canUndoTrash)
        XCTAssertEqual(try library.emptyTrash([a.id]), [a.id])
        XCTAssertTrue(library.canUndoTrash)
        XCTAssertEqual(try library.undoTrash(), [b.id]); XCTAssertNil(try library.item(a.id))
        try library.trashUndoably([b.id]); XCTAssertEqual(try library.emptyTrash([b.id]), [b.id])
        XCTAssertFalse(library.canUndoTrash); XCTAssertEqual(try library.undoTrash(), [])
        let shelf = try XCTUnwrap(library.captureText("Shelf removal"))
        try library.removeFromShelf([shelf.id]); XCTAssertTrue(library.canUndoShelfRemoval)
        XCTAssertEqual(try library.emptyTrash([shelf.id]), [shelf.id])
        XCTAssertFalse(library.canUndoShelfRemoval); XCTAssertEqual(try library.undoShelfRemoval(), [])
    }

    func testPendingFileDeletionsAreRetriedAtLaunchWithOwnershipChecks() throws {
        let f = try fixture(); defer { f.cleanup() }; var library: LibraryStore? = try store(f)
        let managed = try f.image(), external = try f.image(owned: false)
        let db = try LibraryDatabase(url: try XCTUnwrap(library).databaseURL)
        for file in [managed, external] { try db.execute("INSERT INTO purged_files VALUES(?)", [.text(file.path)]) }
        library = nil
        _ = try store(f)
        XCTAssertFalse(exists(managed)); XCTAssertTrue(exists(external))
        XCTAssertTrue(try db.rows("SELECT path FROM purged_files").isEmpty)
    }

    func testSecureDeleteAndCompactionLeaveNoPurgedTextInTheDatabaseFiles() throws {
        let f = try fixture(); defer { f.cleanup() }; let library = try store(f)
        XCTAssertEqual(try LibraryDatabase(url: library.databaseURL).rows("PRAGMA secure_delete").first?["secure_delete"]?.number, 1)
        let marker = "zqxpurgemarker\(UUID().uuidString.prefix(8).lowercased())"
        let text = try XCTUnwrap(library.captureText("secret " + marker + " " + String(repeating: "padding ", count: 2000)))
        let link = try library.captureLink(try XCTUnwrap(URL(string: "https://example.com/\(marker)")))
        try library.update(text.id) { $0.note = marker + " note" }
        let kept = try XCTUnwrap(library.captureText("kept live text"))
        try library.trashUndoably([text.id, link.id])
        XCTAssertEqual(Set(try library.emptyTrash([text.id, link.id])), Set([text.id, link.id]))
        try LibraryStore.compact(library.databaseURL)
        let files = ["library.sqlite", "library.sqlite-wal"].map { library.root.appendingPathComponent($0) }
        for file in files where exists(file) {
            XCTAssertNil(try Data(contentsOf: file).range(of: Data(marker.utf8)), file.lastPathComponent)
        }
        let db = try LibraryDatabase(url: library.databaseURL)
        XCTAssertEqual(try db.rows("PRAGMA freelist_count").first?["freelist_count"]?.number, 0)
        XCTAssertTrue(try db.rows("SELECT 1 FROM metadata WHERE key='purge-compaction'").isEmpty)
        XCTAssertEqual(try library.item(kept.id)?.text, "kept live text")
    }

    func testMigrationBackupsOlderThanThirtyDaysArePruned() throws {
        let f = try fixture(); defer { f.cleanup() }; f.date = Date(); let library = try store(f)
        let backups = library.root.appendingPathComponent("Backups")
        let migration = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil).first)
        XCTAssertTrue(migration.lastPathComponent.hasPrefix("Before-Library-"))
        XCTAssertEqual(try library.pruneBackups(), 0)
        let fresh = backups.appendingPathComponent("Before-Library-\(UUID())"), other = backups.appendingPathComponent("Other backup")
        for folder in [fresh, other] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let outside = f.folder.appendingPathComponent("Outside backup"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = backups.appendingPathComponent("Before-Library-\(UUID())"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        f.date = f.date.addingTimeInterval(31 * day)
        try FileManager.default.setAttributes([.creationDate: f.date.addingTimeInterval(-day)], ofItemAtPath: fresh.path)
        XCTAssertEqual(try library.pruneBackups(), 1)
        XCTAssertFalse(exists(migration))
        for folder in [fresh, other, outside] { XCTAssertTrue(exists(folder), folder.lastPathComponent) }
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
        // The migration marker stays: reopening never migrates or backs up again.
        _ = try store(f)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: backups.path)), Set([fresh, other, link].map(\.lastPathComponent)))
    }

    func testEmptyTrashIsInTheActionsPalette() throws {
        let f = try fixture(); defer { f.cleanup() }
        var context = ActionBarCatalog.Context(); context.origin = .library
        let bindings = KeyboardBindings(defaults: f.defaults)
        func command() throws -> CommandPalette.Command {
            try XCTUnwrap(ActionBarCatalog.entries(context: context, bindings: bindings).first { $0.action == .menu(.emptyTrash) }?.command)
        }
        XCTAssertTrue(try command().isEnabled); XCTAssertEqual(try command().title, L("Empty Trash…"))
        context.libraryAvailable = false
        XCTAssertFalse(try command().isEnabled)
    }
}
