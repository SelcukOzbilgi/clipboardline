import AppKit
import Carbon
#if !STANDALONE_TESTS
import XCTest
@testable import Tendedero
#endif

/// Fork: Command-Z undoes a take-down on the line, next to Backspace.
@MainActor final class ForkKeyboardTests: HistoryTestCase {
    private func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], _ text: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }

    func testCommandZUndoesTakeDownOnTheLineOnly() throws {
        let f = try SyntheticFixture(); defer { f.cleanup() }
        let store = try LibraryStore(defaults: f.defaults, inbox: f.inbox, now: { f.date })
        let text = try XCTUnwrap(store.captureText("take me down"))
        let line = Line(defaults: f.defaults, inbox: f.inbox, breeze: false, library: store)
        let keyboard = LineKeyboard(line: line, onCopy: { _ in }, onPreview: { _ in }, onClose: {})
        line.focusShelf(.texts, requestFocus: false); line.texts.selectAll()
        XCTAssertTrue(keyboard.handle(key(1, [], "s"))); XCTAssertFalse(try store.item(text.id)?.onShelf == true)
        XCTAssertTrue(keyboard.handle(key(6, .command, "z"))); XCTAssertTrue(try store.item(text.id)?.onShelf == true)

        let bindings = line.keyboardBindings
        XCTAssertEqual(bindings.action(for: key(6, .command, "z"), in: .line), .undoRemoveFromLine)
        XCTAssertEqual(bindings.action(for: key(51), in: .line), .undoRemoveFromLine)
        XCTAssertEqual(bindings.action(for: key(6, .command, "z"), in: .library), .undoTrash)
        for context in [KeyboardContext.imagePreview, .textPreview, .linkPreview, .imageMarkup] {
            XCTAssertNotEqual(bindings.action(for: key(6, .command, "z"), in: context), .undoRemoveFromLine)
        }
    }
}
