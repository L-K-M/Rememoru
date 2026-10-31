#if os(macOS)
import XCTest
@testable import RememoruMac

/// Synthetic AX-tree node for Mission Control host tests.
/// Unique name/id and optional child array (nil means unreadable).
private struct AXNode {
    let identifier: String
    let children: [AXNode]?

    init(_ id: String, children: [AXNode]? = []) {
        self.identifier = id
        self.children = children
    }
}

final class MissionControlHostTests: XCTestCase {
    // 1. Dock host containing child "mc" => open with isOpen true
    func testDockWithMcChildIsOpen() {
        let mc = AXNode("mc")
        let dock = AXNode("dock", children: [AXNode("other"), mc])

        let result = MissionControl.observe(
            hosts: [dock],
            children: { $0.children },
            identifier: { $0.identifier }
        )

        if case .open(let group) = result {
            XCTAssertEqual(group.identifier, "mc")
        } else {
            XCTFail("expected .open, got \(#function)")
        }
        XCTAssertEqual(result.isOpen, true)
    }

    // 2. WindowManager host with direct "mc.display" children => HOST itself with isOpen true
    func testDirectDisplayGroupsExposeWindowManagerRoot() {
        let display = AXNode("mc.display")
        let wm = AXNode("wm", children: [display])

        let result = MissionControl.observe(
            hosts: [wm],
            children: { $0.children },
            identifier: { $0.identifier }
        )

        if case .open(let group) = result {
            XCTAssertEqual(group.identifier, "wm")
        } else {
            XCTFail("expected .open, got \(#function)")
        }
        XCTAssertEqual(result.isOpen, true)
    }

    // 3. Readable closed Dock must NOT mask an open direct WindowManager host (either order)
    func testClosedDockDoesNotMaskOpenWindowManager() {
        let display = AXNode("mc.display")
        let closedDock = AXNode("dock", children: [AXNode("something")])
        let openWm = AXNode("wm", children: [display])

        // Dock first, WM second
        let resultA = MissionControl.observe(
            hosts: [closedDock, openWm],
            children: { $0.children },
            identifier: { $0.identifier }
        )
        XCTAssertEqual(resultA.isOpen, true)
        if case .open(let g) = resultA { XCTAssertEqual(g.identifier, "wm") }

        // WM first, Dock second
        let resultB = MissionControl.observe(
            hosts: [openWm, closedDock],
            children: { $0.children },
            identifier: { $0.identifier }
        )
        XCTAssertEqual(resultB.isOpen, true)
        if case .open(let g) = resultB { XCTAssertEqual(g.identifier, "wm") }
    }

    // 4. One unreadable host and other closed => unavailable / nil isOpen
    func testUnreadableHostWithClosedHostYieldsUnavailable() {
        let unreadable = AXNode("unreadable", children: nil)
        let closed = AXNode("closed", children: [])

        let result = MissionControl.observe(
            hosts: [unreadable, closed],
            children: { $0.children },
            identifier: { $0.identifier }
        )

        XCTAssertNil(result.isOpen)
        XCTAssertNil(result.group)
    }

    // 5. Open known host wins even when the other is unreadable, both orders
    func testOpenHostWinsOverUnreadableBothOrders() {
        let mc = AXNode("mc")
        let unreadable = AXNode("unreadable", children: nil)
        let openHost = AXNode("open", children: [mc])

        // Open first, unreadable second
        let resultA = MissionControl.observe(
            hosts: [openHost, unreadable],
            children: { $0.children },
            identifier: { $0.identifier }
        )
        XCTAssertEqual(resultA.isOpen, true)
        if case .open(let g) = resultA { XCTAssertEqual(g.identifier, "mc") }

        // Unreadable first, open second
        let resultB = MissionControl.observe(
            hosts: [unreadable, openHost],
            children: { $0.children },
            identifier: { $0.identifier }
        )
        XCTAssertEqual(resultB.isOpen, true)
        if case .open(let g) = resultB { XCTAssertEqual(g.identifier, "mc") }
    }

    // 6. Unreadable host + direct WindowManager open (mc.display child) wins in both orders
    func testUnreadableHostWithOpenWindowManagerBothOrders() {
        let display = AXNode("mc.display")
        let unreadable = AXNode("unreadable", children: nil)
        let openWm = AXNode("wm", children: [display])

        // WM first, unreadable second
        let resultA = MissionControl.observe(
            hosts: [openWm, unreadable],
            children: { $0.children },
            identifier: { $0.identifier }
        )
        XCTAssertEqual(resultA.isOpen, true)
        if case .open(let g) = resultA { XCTAssertEqual(g.identifier, "wm") }

        // Unreadable first, WM second
        let resultB = MissionControl.observe(
            hosts: [unreadable, openWm],
            children: { $0.children },
            identifier: { $0.identifier }
        )
        XCTAssertEqual(resultB.isOpen, true)
        if case .open(let g) = resultB { XCTAssertEqual(g.identifier, "wm") }
    }

    // 8. Both readable hosts with no MC identifiers => closed false
    func testBothReadableNoMcIsClosed() {
        let hostA = AXNode("a", children: [AXNode("x")])
        let hostB = AXNode("b", children: [AXNode("y")])

        let result = MissionControl.observe(
            hosts: [hostA, hostB],
            children: { $0.children },
            identifier: { $0.identifier }
        )

        XCTAssertEqual(result.isOpen, false)
        XCTAssertNil(result.group)
    }

    // 9. Zero hosts => unavailable
    func testZeroHostsIsUnavailable() {
        let result = MissionControl.observe(
            hosts: [AXNode]() as [AXNode],
            children: { $0.children },
            identifier: { $0.identifier }
        )

        XCTAssertNil(result.isOpen)
        XCTAssertNil(result.group)
    }

    // 10. Arbitrary AXGroup without MC identifiers does not count as open
    func testArbitraryGroupWithoutMcIsNotOpen() {
        let group = AXNode("AXGroup", children: [AXNode("button"), AXNode("text")])

        let result = MissionControl.observe(
            hosts: [group],
            children: { $0.children },
            identifier: { $0.identifier }
        )

        XCTAssertEqual(result.isOpen, false)
        XCTAssertNil(result.group)
    }
}
#endif
