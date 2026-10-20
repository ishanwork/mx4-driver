import Foundation

/// Settings, read from ~/.config/mx4d/config.json when present. Every key is optional.
struct Config {
    /// Turn back/forward side buttons into navigation swipes in apps that ignore mouse buttons 4/5.
    var universalBackForward = true
    var gestureClick: Action = .missionControl
    var gestureUp: Action = .missionControl
    var gestureDown: Action = .appExpose
    var gestureLeft: Action = .spaceLeft
    var gestureRight: Action = .spaceRight
    var sensePanel: Action = .none
    /// Pointer travel (device counts) while holding the gesture button before it counts as a swipe.
    var gestureThreshold = 100
    var verbose = false

    var hasDirectionalGestures: Bool {
        [gestureUp, gestureDown, gestureLeft, gestureRight].contains { $0 != .none }
    }

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
        if let gesture = json["gestureButton"] as? [String: Any] {
            config.gestureClick = action(gesture["click"], config.gestureClick)
            config.gestureUp = action(gesture["up"], config.gestureUp)
            config.gestureDown = action(gesture["down"], config.gestureDown)
            config.gestureLeft = action(gesture["left"], config.gestureLeft)
            config.gestureRight = action(gesture["right"], config.gestureRight)
        }
        config.sensePanel = action(json["sensePanel"], config.sensePanel)
        if let value = json["gestureThreshold"] as? Int { config.gestureThreshold = value }
        if let value = json["verbose"] as? Bool { config.verbose = value }
        return config
    }
}

func log(_ message: String) {
    let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
    FileHandle.standardError.write("\(stamp) \(message)\n".data(using: .utf8)!)
}
