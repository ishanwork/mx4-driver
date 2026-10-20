import CoreGraphics
import Foundation

/// Something a button or gesture can do.
enum Action: Equatable, CustomStringConvertible {
    case none
    case missionControl
    case appExpose
    case showDesktop
    case launchpad
    case spaceLeft
    case spaceRight
    case back
    case forward
    case keys(CGKeyCode, CGEventFlags)

    init?(_ name: String) {
        switch name {
        case "none": self = .none
        case "missionControl": self = .missionControl
        case "appExpose": self = .appExpose
        case "showDesktop": self = .showDesktop
        case "launchpad": self = .launchpad
        case "spaceLeft": self = .spaceLeft
        case "spaceRight": self = .spaceRight
        case "back": self = .back
        case "forward": self = .forward
        default:
            guard let (key, flags) = Keys.parse(name) else { return nil }
            self = .keys(key, flags)
        }
    }

    var description: String {
        switch self {
        case .none: return "none"
        case .missionControl: return "missionControl"
        case .appExpose: return "appExpose"
        case .showDesktop: return "showDesktop"
        case .launchpad: return "launchpad"
        case .spaceLeft: return "spaceLeft"
        case .spaceRight: return "spaceRight"
        case .back: return "back"
        case .forward: return "forward"
        case let .keys(key, flags): return "keys(\(key), 0x\(String(flags.rawValue, radix: 16)))"
        }
    }

    func perform() {
        switch self {
        case .none: break
        case .missionControl: Dock.send("com.apple.expose.awake")
        case .appExpose: Dock.send("com.apple.expose.front.awake")
        case .showDesktop: Dock.send("com.apple.showdesktop.awake")
        case .launchpad: Dock.send("com.apple.launchpad.toggle")
        // Same flags as the system's "Move left/right a space" shortcuts (Control + Fn for arrow keys).
        case .spaceLeft: Synth.key(Keys.leftArrow, flags: [.maskControl, .maskSecondaryFn])
        case .spaceRight: Synth.key(Keys.rightArrow, flags: [.maskControl, .maskSecondaryFn])
        case .back: Synth.navigationSwipe(.left)
        case .forward: Synth.navigationSwipe(.right)
        case let .keys(key, flags): Synth.key(key, flags: flags)
        }
    }
}

/// Private Dock entry point used by the system for Mission Control, App Exposé, etc.
enum Dock {
    private typealias SendNotification = @convention(c) (CFString, Int32) -> Void
    private static let sendNotification: SendNotification? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CoreDockSendNotification") else { return nil }
        return unsafeBitCast(symbol, to: SendNotification.self)
    }()

    static func send(_ notification: String) {
        if let sendNotification {
            sendNotification(notification as CFString, 0)
        } else {
            log("CoreDockSendNotification unavailable; cannot send \(notification)")
        }
    }
}

enum Synth {
    enum SwipeDirection: Int64 {
        // IOHIDSwipeMask
        case left = 0x04
        case right = 0x08
    }

    /// Posts a trackpad-style two-finger navigation swipe, which Safari, Finder, Xcode and most
    /// Apple apps treat as back/forward. Undocumented CGEvent fields; see WebKit's CoreGraphicsTestSPI.h.
    static func navigationSwipe(_ direction: SwipeDirection) {
        guard let began = CGEvent(source: nil), let ended = CGEvent(source: nil),
              let gestureType = CGEventType(rawValue: 29) // NSEventTypeGesture
        else { return }
        let hidType = CGEventField(rawValue: 110)!
        let phase = CGEventField(rawValue: 132)!
        let swipe = CGEventField(rawValue: 115)!
        let navigationSwipe: Int64 = 16 // kIOHIDEventTypeNavigationSwipe

        began.type = gestureType
        began.setIntegerValueField(hidType, value: navigationSwipe)
        began.setIntegerValueField(phase, value: 1) // began
        began.setIntegerValueField(swipe, value: direction.rawValue)

        ended.type = gestureType
        ended.setIntegerValueField(hidType, value: navigationSwipe)
        ended.setIntegerValueField(phase, value: 4) // ended

        began.post(tap: .cgSessionEventTap)
        ended.post(tap: .cgSessionEventTap)
    }

    static func key(_ key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown) else { return }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }
}

/// Parses shortcuts like "cmd+shift+4" or "ctrl+left" into a virtual key code and modifier flags.
enum Keys {
    static let leftArrow: CGKeyCode = 0x7B
    static let rightArrow: CGKeyCode = 0x7C

    private static let modifiers: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand,
        "shift": .maskShift,
        "ctrl": .maskControl, "control": .maskControl,
        "opt": .maskAlternate, "option": .maskAlternate, "alt": .maskAlternate,
        "fn": .maskSecondaryFn,
    ]

    private static let codes: [String: CGKeyCode] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
        "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
        "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
        "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20,
        "[": 0x21, "i": 0x22, "p": 0x23, "return": 0x24, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28,
        ";": 0x29, "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "tab": 0x30,
        "space": 0x31, "`": 0x32, "delete": 0x33, "escape": 0x35, "esc": 0x35,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62,
        "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
        "home": 0x73, "pageup": 0x74, "forwarddelete": 0x75, "end": 0x77, "pagedown": 0x79,
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
    ]

    static func parse(_ shortcut: String) -> (CGKeyCode, CGEventFlags)? {
        var flags: CGEventFlags = []
        var key: CGKeyCode?
        for part in shortcut.lowercased().split(separator: "+").map(String.init) {
            if let modifier = modifiers[part] {
                flags.insert(modifier)
            } else if key == nil, let code = codes[part] {
                key = code
            } else {
                return nil
            }
        }
        guard let key else { return nil }
        if (0x73...0x7E).contains(key) { flags.insert(.maskSecondaryFn) } // arrows/nav keys carry Fn
        return (key, flags)
    }
}
