#if os(macOS)
import CoreGraphics
import Foundation
import RememoruCore

enum Displays {
    private static let colorSync = NativeLibrary(path: "/System/Library/Frameworks/ColorSync.framework/ColorSync")
    private static let coreGraphics = NativeLibrary(
        path: "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
    )

    private typealias CreateUUIDFn = @convention(c) (UInt32) -> Unmanaged<CFUUID>?

    /// `CGDisplayCreateUUIDFromDisplayID` lives in ColorSync on current
    /// macOS; older releases exported it from CoreGraphics. Looking only in
    /// CoreGraphics is why it appeared to be "gone" on macOS 26.
    private static let createUUID: CreateUUIDFn? =
        colorSync.symbol("CGDisplayCreateUUIDFromDisplayID", as: CreateUUIDFn.self)
        ?? coreGraphics.symbol("CGDisplayCreateUUIDFromDisplayID", as: CreateUUIDFn.self)

    static var canReadUUIDs: Bool { createUUID != nil }

    static func uuid(of display: CGDirectDisplayID) -> String? {
        guard let createUUID, let uuid = createUUID(display)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid) else { return nil }
        return string as String
    }

    static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// Connected displays in global (top-left origin) coordinates, keyed by
    /// the uuid SkyLight uses as "Display Identifier".
    ///
    /// - Parameter skyLightOrder: SkyLight display identifiers in their
    ///   enumeration order, used only when the uuid lookup is unavailable.
    static func current(skyLightOrder: [String]) -> [LiveDisplay] {
        let main = CGMainDisplayID()
        let ids = activeDisplayIDs()
        let orderFallback = ids.count == skyLightOrder.count ? skyLightOrder : []
        return ids.enumerated().compactMap { index, id in
            let uuid = uuid(of: id) ?? (index < orderFallback.count ? orderFallback[index] : nil)
            guard let uuid else { return nil }
            let bounds = CGDisplayBounds(id)
            return LiveDisplay(
                id: id,
                uuid: uuid,
                frame: Rect(x: bounds.origin.x, y: bounds.origin.y, w: bounds.width, h: bounds.height),
                isMain: id == main
            )
        }
    }
}

extension Rect {
    init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, w: rect.width, h: rect.height)
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}
#endif
