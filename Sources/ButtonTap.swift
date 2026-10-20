import CoreGraphics
import Darwin
import Foundation

/// Watches extra mouse buttons system-wide.
/// - Back/forward (buttons 4/5): in apps that only understand trackpad swipes (Safari, Finder,
///   Xcode, ...) they become navigation swipes; apps that handle them natively (Chrome, VS Code, ...)
///   get the original click.
/// - Button 6: what the MX gesture button sends when it is *not* diverted, i.e. the mouse lost
///   its HID++ setup (power cycle, deep sleep). `onNativeGestureButton` gets a chance to handle it.
final class ButtonTap {
    private static let swipeApps = [
        "com.apple.*",
        "com.binarynights.ForkLift*",
        "org.mozilla.firefox",
        "com.operasoftware.Opera",
    ]

    private var tap: CFMachPort?
    private var swallowedButtons: Set<Int64> = []
    private var bundleIDCache: [String: String] = [:]
    let universalBackForward: Bool
    let verbose: Bool
    /// Returns true if it handled the press (the click is then swallowed).
    var onNativeGestureButton: (() -> Bool)?

    init(universalBackForward: Bool, verbose: Bool) {
        self.universalBackForward = universalBackForward
        self.verbose = verbose
    }

    /// Fails until the process has Accessibility permission.
    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.otherMouseDown.rawValue) | CGEventMask(1 << CGEventType.otherMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, context in
                                              let this = Unmanaged<ButtonTap>.fromOpaque(context!).takeUnretainedValue()
                                              return this.handle(type, event)
                                          }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        if type == .otherMouseUp {
            return swallowedButtons.remove(button) != nil ? nil : Unmanaged.passUnretained(event)
        }
        if button == 5, let onNativeGestureButton, onNativeGestureButton() {
            swallowedButtons.insert(button)
            return nil
        }
        guard universalBackForward, button == 3 || button == 4 else { return Unmanaged.passUnretained(event) }

        let bundleID = targetBundleID(event)
        guard let bundleID, Self.prefersSwipe(bundleID) else {
            if verbose { log("button \(button) -> native (\(bundleID ?? "unknown app"))") }
            return Unmanaged.passUnretained(event)
        }
        if verbose { log("button \(button) -> swipe (\(bundleID))") }
        swallowedButtons.insert(button)
        (button == 3 ? Action.back : Action.forward).perform()
        return nil
    }

    static func prefersSwipe(_ bundleID: String) -> Bool {
        swipeApps.contains { pattern in
            pattern.hasSuffix("*") ? bundleID.hasPrefix(pattern.dropLast()) : bundleID == pattern
        }
    }

    /// The app that owns the window under the pointer.
    private func targetBundleID(_ event: CGEvent) -> String? {
        var pid = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        if pid == 0 { pid = windowOwner(at: event.location) ?? 0 }
        guard pid != 0 else { return nil }
        return bundleID(pid: pid)
    }

    private func windowOwner(at point: CGPoint) -> pid_t? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.contains(point),
                  (window[kCGWindowLayer as String] as? Int) == 0 else { continue }
            return window[kCGWindowOwnerPID as String] as? pid_t
        }
        return nil
    }

    private func bundleID(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        if let cached = bundleIDCache[path] { return cached }
        // Use the outermost .app bundle so helper processes resolve to their host app.
        guard let range = path.range(of: ".app/") else { return nil }
        let bundlePath = String(path[..<range.lowerBound]) + ".app"
        let id = Bundle(path: bundlePath)?.bundleIdentifier
        if let id { bundleIDCache[path] = id }
        return id
    }
}
