#if os(macOS)
import AppKit
import ApplicationServices
import RememoruCore

/// Dock owns the visible order. The bridged WindowServer reorder can
/// change its reported array without moving Mission Control thumbnails.
enum SpaceOrderRestorer {
    static var hasFixedOrder: Bool {
        (UserDefaults(suiteName: "com.apple.dock")?.object(forKey: "mru-spaces") as? NSNumber)?.boolValue == false
    }

    static func captureStillValid(_ state: LiveState) -> Bool {
        state.displays.allSatisfy { display in
            let original = state.spaces(onDisplay: display.uuid).filter { $0.kind.isRestorable }
            let current = spaces(on: display)
            return sameMembership(current, as: original)
                && current.first(where: \.isActive)?.id == original.first(where: \.isActive)?.id
        }
    }

    static func captureOrder(display: LiveDisplay, original: [LiveSpace]) throws -> [UInt64] {
        func failure(_ message: String) -> NSError {
            NSError(domain: "Rememoru.SpaceOrder", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard original.count > 1 else { return original.map(\.id) }
        guard hasFixedOrder else {
            throw failure("Turn off Automatically rearrange Spaces based on most recent use in Desktop & Dock, then save again.")
        }
        guard Permissions.isGranted(.accessibility) else {
            throw failure("Grant Accessibility access so Rememoru can verify the visible Space order, then save again.")
        }
        guard let active = original.first(where: \.isActive)?.id else {
            throw failure("Could not read the active Space before saving. Try saving again.")
        }
        let pointer = CGEvent(source: nil)?.location
        defer { if let pointer { CGWarpMouseCursorPosition(pointer) } }
        let deadline = Date().addingTimeInterval(max(15, Double(original.count) * 4))
        let order = survey(display: display, original: original, canContinue: { Date() < deadline && hasFixedOrder })
        let cleanupDeadline = Date().addingTimeInterval(8)
        let canCleanUp = { Date() < cleanupDeadline }
        guard MissionControl.close(canContinue: canCleanUp),
              SpaceSwitcher.show(spaceID: active, display: display, readSpaces: { SkyLight.managedSpaces().spaces },
                                 canContinue: canCleanUp) != nil else {
            throw failure("Could not return to the original Space after checking order. The layout was not saved.")
        }
        guard let order, sameMembership(spaces(on: display), as: original) else {
            throw failure("Could not verify the visible Space order. Wait for Space transitions to finish, then save again.")
        }
        return order
    }

    static func restore(
        desired: [UInt64], display: LiveDisplay, cancellation: CancellationFlag, log: (String) -> Void
    ) -> RestoreReport.Outcome {
        guard desired.count > 1 else { return .done }
        guard hasFixedOrder else {
            return .failed("turn off Automatically rearrange Spaces based on most recent use in Desktop & Dock, then retry")
        }
        let original = spaces(on: display)
        guard let active = original.first(where: \.isActive)?.id else {
            return .failed("could not read the original active Space")
        }
        let pointer = CGEvent(source: nil)?.location
        defer { if let pointer { CGWarpMouseCursorPosition(pointer) } }
        let deadline = Date().addingTimeInterval(max(30, Double(original.count) * 12))
        let canContinue = { !cancellation.isCancelled && Date() < deadline && hasFixedOrder }
        let outcome = arrange(desired: desired, display: display, original: original,
                              canContinue: canContinue, log: log)

        // Even an unsuccessful drag or cancelled survey can change the
        // active Space. Cleanup has its own deadline and ignores cancellation.
        let cleanupDeadline = Date().addingTimeInterval(8)
        let canCleanUp = { Date() < cleanupDeadline }
        guard MissionControl.close(canContinue: canCleanUp),
              SpaceSwitcher.show(spaceID: active, display: display, readSpaces: { SkyLight.managedSpaces().spaces },
                                 canContinue: canCleanUp, trace: log) != nil else {
            log("  Space-order result before cleanup: \(outcome)")
            return .failed("could not return to the original Space after checking order")
        }
        return cancellation.isCancelled ? .skipped("cancelled") : outcome
    }

    private static func arrange(
        desired: [UInt64], display: LiveDisplay, original: [LiveSpace],
        canContinue: () -> Bool, log: (String) -> Void
    ) -> RestoreReport.Outcome {
        guard let initial = survey(display: display, original: original, canContinue: canContinue, trace: log) else {
            return .failed("could not verify the Dock's Space order")
        }
        log("  Dock Space order: \(initial)")
        guard let moves = SpaceOrdering.moves(current: initial, desired: desired) else {
            return .failed("Space membership changed before reordering")
        }
        var current = initial
        for move in moves {
            guard canContinue() else { return .failed("Space-order restore timed out or was cancelled") }
            log("  move Space \(move.spaceID) before \(move.beforeID) in Mission Control")
            guard moveThumbnail(move, current: current, display: display, original: original,
                                canContinue: canContinue),
                  MissionControl.close(canContinue: canContinue) else {
                return .failed("could not move the Space thumbnail in Mission Control")
            }
            let actual = survey(display: display, original: original, canContinue: canContinue, trace: log)
            log("  observed Dock Space order after move: \(actual.map { String(describing: $0) } ?? "unavailable")")
            guard let actual, actual == move.expectedOrder else {
                return .failed("Mission Control's Space order did not match the requested move")
            }
            current = actual
            log("  confirmed Dock Space order: \(actual)")
        }
        return .done
    }

    private static func spaces(on display: LiveDisplay) -> [LiveSpace] {
        SkyLight.managedSpaces().spaces.filter { $0.displayUUID == display.uuid && $0.kind.isRestorable }
    }

    private static func sameMembership(_ current: [LiveSpace], as original: [LiveSpace]) -> Bool {
        guard Set(current.map(\.id)) == Set(original.map(\.id)), current.count == original.count else { return false }
        return original.allSatisfy { before in
            guard let after = current.first(where: { $0.id == before.id }) else { return false }
            return before.kind == after.kind
                && before.tiles.compactMap(\.windowID).sorted() == after.tiles.compactMap(\.windowID).sorted()
        }
    }

    private static func survey(
        display: LiveDisplay, original: [LiveSpace], canContinue: () -> Bool, trace: (String) -> Void = { _ in }
    ) -> [UInt64]? {
        guard canContinue(), MissionControl.close(canContinue: canContinue) else { return nil }
        // Dock's AX tree can disappear before WindowServer finishes restoring
        // the active flag from the overview. Do not seed navigation from that
        // transient desktop ID.
        let closedAt = Date()
        var stableSince = Date()
        var previousActive: UInt64?
        let settled = MissionControl.wait(timeout: 2, interval: 0.05) { () -> [LiveSpace]? in
            guard canContinue() else { return nil }
            let current = spaces(on: display)
            guard sameMembership(current, as: original), let active = current.first(where: \.isActive)?.id else {
                stableSince = Date()
                return nil
            }
            if active != previousActive { previousActive = active; stableSince = Date() }
            return Date().timeIntervalSince(closedAt) >= 0.5 && Date().timeIntervalSince(stableSince) >= 0.3
                ? current : nil
        }
        guard canContinue(), let initial = settled, let active = initial.first(where: \.isActive)?.id,
              var survey = SpaceOrderSurvey(knownIDs: initial.map(\.id), activeID: active) else {
            trace("  Space-order survey: initial membership or active Space unavailable")
            return nil
        }
        var previous = active
        while let direction = survey.nextDirection() {
            guard canContinue() else { return nil }
            // Allow Dock's previous Space transition to finish before the
            // next gesture. Recheck cancellation after waiting.
            Thread.sleep(forTimeInterval: 0.3)
            guard canContinue() else { return nil }
            SpaceSwitcher.swipe(steps: direction.rawValue, on: display)
            var observed: UInt64?
            var valid = true
            _ = MissionControl.wait(timeout: 1.5, interval: 0.05) { () -> Bool? in
                guard canContinue() else { valid = false; return false }
                let current = spaces(on: display)
                guard sameMembership(current, as: original) else {
                    trace("  Space-order survey: membership changed to \(current.map(\.id))")
                    valid = false
                    return false
                }
                observed = current.first(where: \.isActive)?.id
                return observed != nil && observed != previous ? true : nil
            }
            trace("  Space-order survey \(direction) from=\(previous) to=\(observed.map(String.init) ?? "unknown")")
            guard canContinue(), valid, survey.observe(activeID: observed), let observed else { return nil }
            previous = observed
        }
        guard canContinue(), !survey.failed else { return nil }
        return survey.order
    }

    private static func moveThumbnail(
        _ move: SpaceOrdering.Move, current: [UInt64], display: LiveDisplay, original: [LiveSpace],
        canContinue: () -> Bool
    ) -> Bool {
        guard canContinue(), sameMembership(spaces(on: display), as: original),
              let source = current.firstIndex(of: move.spaceID), let target = current.firstIndex(of: move.beforeID),
              canContinue(), MissionControl.open() != nil, canContinue() else { return false }
        // The AX list appears before Dock finishes laying out thumbnails.
        // Require settled geometry before binding surveyed IDs to buttons.
        var previousFrames: [Rect] = []
        var stableSince = Date()
        guard let buttons = MissionControl.wait(timeout: 2, { () -> [AXElement]? in
            guard canContinue() else { return nil }
            let buttons = orderedButtons(display: display.id)
            let frames = buttons.compactMap(\.frame)
            guard buttons.count == current.count, frames.count == current.count,
                  buttons.allSatisfy({ $0.role == kAXButtonRole }) else { return nil }
            if frames != previousFrames {
                previousFrames = frames
                stableSince = Date()
            }
            return Date().timeIntervalSince(stableSince) >= 0.3 ? buttons : nil
        }), let bar = MissionControl.spacesGroup(display: display.id)?.frame else { return false }
        let frames = buttons.compactMap(\.frame)
        guard frames.count == buttons.count,
              let path = SpaceDragGeometry.path(from: source, before: target, frames: frames, inside: bar),
              canContinue(), sameMembership(spaces(on: display), as: original) else { return false }
        let fresh = orderedButtons(display: display.id)
        guard fresh.count == buttons.count, zip(fresh, buttons).allSatisfy({ CFEqual($0.element, $1.element) }),
              fresh.compactMap(\.frame) == frames, buttons[source].bool(kAXEnabledAttribute) == true,
              exactHit(buttons[source], x: path.startX, y: path.startY), canContinue() else { return false }
        return drag(path, canContinue: canContinue)
    }

    private static func orderedButtons(display: UInt32) -> [AXElement] {
        MissionControl.spaceButtons(display: display).sorted { ($0.frame?.x ?? .infinity) < ($1.frame?.x ?? .infinity) }
    }

    private static func exactHit(_ button: AXElement, x: Double, y: Double) -> Bool {
        var raw: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXElement.systemWide.element, Float(x), Float(y), &raw) == .success,
              let raw else { return false }
        var hit: AXElement? = AXElement(element: raw)
        for _ in 0..<8 {
            guard let element = hit else { return false }
            if CFEqual(element.element, button.element) { return true }
            hit = element.element(kAXParentAttribute)
        }
        return false
    }

    private static func drag(_ path: SpaceDragGeometry.Path, canContinue: () -> Bool) -> Bool {
        let start = CGPoint(x: path.startX, y: path.startY)
        let end = CGPoint(x: path.endX, y: path.endY)
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                 mouseCursorPosition: start, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                               mouseCursorPosition: end, mouseButton: .left), canContinue() else { return false }
        let steps = 12
        var events: [CGEvent] = []
        for step in 1...steps {
            let fraction = Double(step) / Double(steps)
            let point = CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
            guard let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                                      mouseCursorPosition: point, mouseButton: .left) else { return false }
            events.append(event)
        }
        guard canContinue(), MissionControl.isOpen else { return false }
        CGWarpMouseCursorPosition(start)
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap)
        // Once down is posted, finish the short drag into the safe gap even
        // on cancellation. Releasing over a thumbnail risks creating a pair.
        defer { up.post(tap: .cghidEventTap) }
        Thread.sleep(forTimeInterval: 0.15)
        for event in events {
            event.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.03)
        }
        return true
    }
}
#endif
