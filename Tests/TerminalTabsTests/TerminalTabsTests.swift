import XCTest
import GhosttyBridge
@testable import TerminalTabs

final class TerminalTabsTests: XCTestCase {
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
        store.newTab()
        XCTAssertEqual(store.tabs.count, 2)
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
}
