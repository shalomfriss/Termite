import XCTest
import GhosttyBridge
@testable import TerminalTabs

final class TerminalTabsTests: XCTestCase {
    func testCommandLineTrackerHandlesTypingAndBackspace() {
        var tracker = CommandLineTracker()
        tracker.append(Data("pww".utf8))
        tracker.append(Data([0x7F]))
        tracker.append(Data("d".utf8))
        XCTAssertEqual(tracker.submit(), "pwd")
        XCTAssertEqual(tracker.text, "")
    }

    @MainActor
    func testStoreAlwaysKeepsOneTab() {
        let store = TerminalStore()
        XCTAssertEqual(store.tabs.count, 1)
        store.close()
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertNotNil(store.selectedID)
    }

    @MainActor
    func testTabSelectionWraps() {
        let store = TerminalStore()
        store.newTab()
        let second = store.selectedID
        store.selectNext(delta: 1)
        XCTAssertEqual(store.selectedID, store.tabs[0].id)
        store.selectNext(delta: -1)
        XCTAssertEqual(store.selectedID, second)
    }

    @MainActor
    func testTabGroupLifecycle() {
        let store = TerminalStore()
        XCTAssertEqual(store.groups.count, 1)
        store.newGroup()
        XCTAssertEqual(store.groups.count, 2)
        let selectedGroupID = try! XCTUnwrap(store.selectedGroupID)
        store.renameGroup(selectedGroupID, to: "Development")
        XCTAssertEqual(store.selectedGroup?.name, "Development")
        store.toggleGroupCollapsed(selectedGroupID)
        XCTAssertTrue(store.selectedGroup?.isCollapsed == true)
        store.selectAndToggleGroup(selectedGroupID)
        XCTAssertFalse(store.selectedGroup?.isCollapsed ?? true)
        store.newTab()
        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertFalse(store.selectedGroup?.isCollapsed ?? true)
        store.closeGroup(selectedGroupID)
        XCTAssertEqual(store.groups.count, 1)
        XCTAssertNotNil(store.selected)
    }

    @MainActor
    func testTabLayoutCanChangeAndHide() {
        let store = TerminalStore()
        store.tabOrientation = .vertical
        store.isTabBarVisible = false
        XCTAssertEqual(store.tabOrientation, .vertical)
        XCTAssertFalse(store.isTabBarVisible)
        store.tabOrientation = .horizontal
        store.isTabBarVisible = true
    }

    @MainActor
    func testShellOutputIsParsedByGhostty() throws {
        if let error = gt_runtime_error() {
            throw XCTSkip(String(cString: error))
        }
        let session = TerminalSession(cols: 80, rows: 24)
        guard let handle = session.handle else {
            return XCTFail(session.error ?? "Could not create terminal session")
        }
        session.write(Data("printf '__ghostty_probe__\\n'\n".utf8))

        var contents = ""
        for _ in 0..<100 {
            usleep(20_000)
            session.poll()
            guard let frame = gt_session_frame(handle), let cells = frame.pointee.cells else { continue }
            contents = (0..<(Int(frame.pointee.cols) * Int(frame.pointee.rows))).map { index in
                let cell = cells[index]
                return withUnsafeBytes(of: cell.text) { raw in
                    String(decoding: raw.prefix(Int(cell.text_len)), as: UTF8.self)
                }
            }.joined()
            if contents.contains("__ghostty_probe__") { break }
        }
        XCTAssertTrue(contents.contains("__ghostty_probe__"))
    }

    @MainActor
    func testUserCommandCreatesSemanticBlock() throws {
        if let error = gt_runtime_error() { throw XCTSkip(String(cString: error)) }
        let session = TerminalSession(cols: 80, rows: 24)
        let handle = try XCTUnwrap(session.handle)
        session.sendUserInput(Data("printf block_probe".utf8))
        session.sendUserInput(Data([0x0D]))

        for _ in 0..<50 {
            usleep(10_000)
            session.poll()
        }
        let frame = try XCTUnwrap(gt_session_frame(handle))
        let cells = try XCTUnwrap(frame.pointee.cells)
        let hasInput = (0..<(Int(frame.pointee.cols) * Int(frame.pointee.rows))).contains {
            cells[$0].semantic_content == UInt8(GT_SEMANTIC_INPUT)
        }
        let hasPromptRow = (0..<Int(frame.pointee.rows)).contains {
            frame.pointee.row_semantics?[$0] == 1
        }
        XCTAssertTrue(hasInput)
        XCTAssertTrue(hasPromptRow)
    }

    @MainActor
    func testTypingDoesNotMoveToANewLine() throws {
        if let error = gt_runtime_error() { throw XCTSkip(String(cString: error)) }
        let session = TerminalSession(cols: 80, rows: 24)
        let handle = try XCTUnwrap(session.handle)
        for _ in 0..<50 {
            usleep(10_000)
            session.poll()
        }
        let before = try XCTUnwrap(gt_session_frame(handle)).pointee.cursor_y
        session.sendUserInput(Data("x".utf8))
        for _ in 0..<10 {
            usleep(10_000)
            session.poll()
        }
        let after = try XCTUnwrap(gt_session_frame(handle)).pointee.cursor_y
        XCTAssertEqual(after, before)
    }

}
