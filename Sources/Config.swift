import Foundation

/// What a diverted button does: tap, hold, and hold + move in each direction.
struct ButtonActions {
    var tap: Action = .none
    var hold: Action = .none
    var up: Action = .none
    var down: Action = .none
    var left: Action = .none
    var right: Action = .none

    var hasDirections: Bool { [up, down, left, right].contains { $0 != .none } }
    var isMapped: Bool { [tap, hold, up, down, left, right].contains { $0 != .none } }
    /// With no hold or swipe to wait for, the tap action can fire on press.
    var firesOnPress: Bool { hold == .none && !hasDirections }
}

/// Settings, read from ~/.config/mx4d/config.json when present. Every key is optional.
struct Config {
    /// Turn back/forward side buttons into navigation swipes in apps that ignore mouse buttons 4/5.
    var universalBackForward = true
    var gestureButton = ButtonActions(tap: .missionControl, up: .missionControl, down: .appExpose,
                                      left: .spaceLeft, right: .spaceRight)
    var sensePanel = ButtonActions()
    /// Pointer travel (device counts) while holding a button before it counts as a swipe.
    var gestureThreshold = 100
    /// Further travel that repeats a Space swipe while the button stays held (default: 2x threshold).
    var gestureStep = 200
    /// Haptic waveform the mouse plays when a swipe fires (MX Master 4 only), or nil for none.
    var hapticFeedback: HapticWaveform?
    var verbose = false

    static var path: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("mx4d/config.json")
    }

    static func load() -> Config {
        var config = Config()
        guard let data = try? Data(contentsOf: path) else { return config }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            log("Ignoring \(path.path): not a JSON object")
            return config
        }
        func action(_ value: Any?, _ fallback: Action) -> Action {
            guard let name = value as? String else { return fallback }
            guard let action = Action(name) else {
                log("Unknown action \"\(name)\" in config; keeping \(fallback)")
                return fallback
            }
            return action
        }
        if let value = json["universalBackForward"] as? Bool { config.universalBackForward = value }
        // A button takes either one action (fires on press) or
        // {"tap"/"click": ..., "hold": ..., "up": ..., "down": ..., "left": ..., "right": ...}.
        func buttonActions(_ value: Any?, _ fallback: ButtonActions) -> ButtonActions {
            guard let dict = value as? [String: Any] else {
                guard value != nil else { return fallback }
                return ButtonActions(tap: action(value, .none))
            }
            var result = fallback
            result.tap = action(dict["tap"] ?? dict["click"], result.tap)
            result.hold = action(dict["hold"], result.hold)
            result.up = action(dict["up"], result.up)
            result.down = action(dict["down"], result.down)
            result.left = action(dict["left"], result.left)
            result.right = action(dict["right"], result.right)
            return result
        }
        config.gestureButton = buttonActions(json["gestureButton"], config.gestureButton)
        config.sensePanel = buttonActions(json["sensePanel"], config.sensePanel)
        if let value = json["gestureThreshold"] as? Int { config.gestureThreshold = value }
        config.gestureStep = max(1, (json["gestureStep"] as? Int) ?? config.gestureThreshold * 2)
        if let name = json["hapticFeedback"] as? String, name != "none" {
            if let waveform = HapticWaveform(name: name) {
                config.hapticFeedback = waveform
            } else {
                log("Unknown hapticFeedback \"\(name)\" in config; try one of " + HapticWaveform.allCases.map(\.name).joined(separator: ", "))
            }
        }
        if let value = json["verbose"] as? Bool { config.verbose = value }
        return config
    }
}

func log(_ message: String) {
    let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
    FileHandle.standardError.write("\(stamp) \(message)\n".data(using: .utf8)!)
}
