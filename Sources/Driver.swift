import Foundation
import IOKit.hid

/// Control IDs from HID++ feature 0x1B04 (REPROG_CONTROLS_V4).
enum CID {
    static let gestureButton: UInt16 = 0x00C3 // Logitech: "App Switch Gesture"
    static let sensePanel: UInt16 = 0x01A0 // MX Master 4 haptic thumb panel
}

/// Owns the HID++ connections and turns diverted button presses into actions.
final class Driver {
    private static let holdDelay: TimeInterval = 0.4
    private let config: Config
    private let manager: IOHIDManager
    private var transports: [IOHIDDevice: HIDPPTransport] = [:]
    private var mice: [ObjectIdentifier: [UInt8: Mouse]] = [:] // transport -> device index -> mouse
    private var gestureSlots: [ObjectIdentifier: Set<UInt8>] = [:] // slots known to have a gesture button
    private var recoveryPending = false
    private var pendingConfigures: Set<Slot> = []

    private struct Slot: Hashable {
        let transport: ObjectIdentifier
        let index: UInt8
    }

    /// Press state of one diverted button.
    final class Press {
        var dx = 0
        var dy = 0
        var fired = false // a hold or swipe action fired, so release does nothing
        var skipNextMove = true
    }

    /// A configured mouse and its button state.
    final class Mouse {
        let device: HIDPPDevice
        let name: String
        let reprogIndex: UInt8
        let wirelessStatusIndex: UInt8?
        let hapticIndex: UInt8?
        let diverted: [UInt16]
        var pressed: Set<UInt16> = []
        var presses: [UInt16: Press] = [:] // diverted buttons currently held

        init(device: HIDPPDevice, name: String, reprogIndex: UInt8, wirelessStatusIndex: UInt8?,
             hapticIndex: UInt8?, diverted: [UInt16]) {
            self.device = device
            self.name = name
            self.reprogIndex = reprogIndex
            self.wirelessStatusIndex = wirelessStatusIndex
            self.hapticIndex = hapticIndex
            self.diverted = diverted
        }
    }

    private func actions(for cid: UInt16) -> ButtonActions {
        cid == CID.gestureButton ? config.gestureButton : config.sensePanel
    }

    private static func label(_ cid: UInt16) -> String {
        cid == CID.gestureButton ? "gesture" : "sense panel"
    }

    init(config: Config) {
        self.config = config
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func start() {
        IOHIDManagerSetDeviceMatchingMultiple(manager, hidppMatching() as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            let driver = Unmanaged<Driver>.fromOpaque(context!).takeUnretainedValue()
            DispatchQueue.main.async { driver.deviceAdded(device) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            let driver = Unmanaged<Driver>.fromOpaque(context!).takeUnretainedValue()
            driver.deviceRemoved(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            log(String(format: "IOHIDManagerOpen failed: 0x%08X", result))
        }
    }

    /// Hands the buttons back to the firmware so they behave natively after we exit.
    func stop() {
        for mouse in mice.values.flatMap(\.values) {
            for cid in mouse.diverted { mouse.device.undivert(cid) }
        }
        mice.removeAll()
    }

    // MARK: Device lifecycle

    private func deviceAdded(_ hidDevice: IOHIDDevice) {
        guard transports[hidDevice] == nil else { return }
        let transport = HIDPPTransport(device: hidDevice)
        transports[hidDevice] = transport
        transport.onNotification = { [weak self, weak transport] report in
            guard let self, let transport else { return }
            self.handleNotification(report, from: transport)
        }
        log("Found \(transport.productName) (\(transport.isReceiver ? "receiver" : "Bluetooth"))")
        if transport.isReceiver {
            enableConnectionNotifications(transport)
            for index: UInt8 in 1...6 { configure(transport, index: index) }
        } else {
            configure(transport, index: HIDPP.directIndex)
        }
    }

    private func deviceRemoved(_ hidDevice: IOHIDDevice) {
        guard let transport = transports.removeValue(forKey: hidDevice) else { return }
        mice[ObjectIdentifier(transport)] = nil
        gestureSlots[ObjectIdentifier(transport)] = nil
        log("Lost \(transport.productName)")
    }

    /// Ask the receiver to report device connect/disconnect (register 0x00, "wireless notifications").
    private func enableConnectionNotifications(_ transport: HIDPPTransport) {
        if !transport.setReceiverRegister(0x00, [0x00, 0x01, 0x00]) {
            log("Could not enable receiver connection notifications")
        }
    }

    private func configure(_ transport: HIDPPTransport, index: UInt8) {
        let key = ObjectIdentifier(transport)
        mice[key]?[index] = nil
        let device = HIDPPDevice(transport: transport, index: index)
        // A sleeping mouse answers once it wakes for its next radio poll, which can take ~1 s.
        guard device.ping(timeout: 2.0) != nil,
              let reprogIndex = device.featureIndex(HIDPP.featureReprogControlsV4) else { return }
        let controls = Dictionary(device.controls().map { ($0.cid, $0) }, uniquingKeysWith: { a, _ in a })
        if controls[CID.gestureButton] != nil { gestureSlots[key, default: []].insert(index) }
        var diverted: [UInt16] = []
        // The gesture button is always diverted so we can recover its click even when unmapped.
        for cid in [CID.gestureButton, CID.sensePanel] {
            let mapped = actions(for: cid)
            guard cid == CID.gestureButton || mapped.isMapped, let control = controls[cid], control.isDivertable else { continue }
            let rawXY = mapped.hasDirections && control.supportsRawXY
            if device.divert(cid, rawXY: rawXY) { diverted.append(cid) }
        }
        guard !diverted.isEmpty else { return }
        let name = device.name ?? "device \(index)"
        let mouse = Mouse(device: device, name: name, reprogIndex: reprogIndex,
                          wirelessStatusIndex: device.featureIndex(HIDPP.featureWirelessStatus),
                          hapticIndex: config.hapticFeedback == nil ? nil : device.featureIndex(HIDPP.featureHaptics),
                          diverted: diverted)
        mice[key, default: [:]][index] = mouse
        log("Configured \(name) (slot \(index)): diverted " + diverted.map { String(format: "0x%04X", $0) }.joined(separator: ", "))
    }

    /// Reconnects usually produce both a receiver link-up and a device "reconfigure me" event;
    /// coalesce them into one configure pass.
    private func scheduleConfigure(_ transport: HIDPPTransport, index: UInt8, after delay: TimeInterval) {
        let slot = Slot(transport: ObjectIdentifier(transport), index: index)
        guard pendingConfigures.insert(slot).inserted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak transport] in
            guard let self else { return }
            self.pendingConfigures.remove(slot)
            guard let transport, self.transports.values.contains(where: { $0 === transport }) else { return }
            self.configure(transport, index: index)
        }
    }

    /// The gesture button arrived as plain mouse button 6, so a mouse lost its diversion without
    /// telling us (power cycle, deep sleep). Do the click action now and re-divert in the background.
    func nativeGestureButtonPressed() -> Bool {
        guard !transports.isEmpty else { return false }
        run(config.gestureButton.tap, "gesture tap (button not diverted)")
        guard !recoveryPending else { return true }
        recoveryPending = true
        DispatchQueue.main.async { [self] in
            recoveryPending = false
            for transport in transports.values {
                let known = gestureSlots[ObjectIdentifier(transport)] ?? []
                let slots: [UInt8] = !known.isEmpty ? Array(known) : transport.isReceiver ? Array(1...6) : [HIDPP.directIndex]
                for index in slots { configure(transport, index: index) }
            }
        }
        return true
    }

    // MARK: Notifications

    private func handleNotification(_ r: [UInt8], from transport: HIDPPTransport) {
        let index = r[1]
        // Receiver: device (re)connected. Diversion does not survive a power cycle, so re-apply it.
        if transport.isReceiver && r[2] == 0x41 && r.count >= 5 {
            let linkUp = r[4] & 0x40 == 0
            if config.verbose { log("slot \(index) link \(linkUp ? "up" : "down")") }
            if linkUp { scheduleConfigure(transport, index: index, after: 0.2) }
            return
        }
        guard let mouse = mice[ObjectIdentifier(transport)]?[index], r.count >= 8 else { return }
        let event = r[3] >> 4
        if r[2] == mouse.wirelessStatusIndex && event == 0 {
            // WIRELESS_DEVICE_STATUS: the device asks software to reconfigure it.
            if config.verbose { log("\(mouse.name) requested reconfiguration") }
            scheduleConfigure(transport, index: index, after: 0.2)
        } else if r[2] == mouse.reprogIndex && event == 0 {
            let cids = stride(from: 4, to: min(r.count, 12), by: 2).map { UInt16(r[$0]) << 8 | UInt16(r[$0 + 1]) }
            buttonsChanged(mouse, pressed: Set(cids.filter { $0 != 0 }))
        } else if r[2] == mouse.reprogIndex && event == 1 {
            let dx = Int(Int16(bitPattern: UInt16(r[4]) << 8 | UInt16(r[5])))
            let dy = Int(Int16(bitPattern: UInt16(r[6]) << 8 | UInt16(r[7])))
            gestureMoved(mouse, dx: dx, dy: dy)
        }
    }

    private func buttonsChanged(_ mouse: Mouse, pressed: Set<UInt16>) {
        let down = pressed.subtracting(mouse.pressed)
        let up = mouse.pressed.subtracting(pressed)
        mouse.pressed = pressed

        for cid in down where mouse.diverted.contains(cid) {
            let mapped = actions(for: cid)
            let press = Press()
            mouse.presses[cid] = press
            if mapped.firesOnPress {
                run(mapped.tap, "\(Self.label(cid)) press")
            } else if mapped.hold != .none {
                // Holding past the delay fires the hold action instead of the tap.
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay) { [weak self, weak mouse] in
                    guard let self, let mouse, mouse.presses[cid] === press, !press.fired else { return }
                    press.fired = true
                    self.run(mapped.hold, "\(Self.label(cid)) hold")
                }
            }
        }
        for cid in up {
            guard let press = mouse.presses.removeValue(forKey: cid) else { continue }
            let mapped = actions(for: cid)
            if config.verbose && mapped.hasDirections { log("\(Self.label(cid)) released: travel dx=\(press.dx) dy=\(press.dy)") }
            if !mapped.firesOnPress && !press.fired { run(mapped.tap, "\(Self.label(cid)) tap") }
        }
    }

    private func gestureMoved(_ mouse: Mouse, dx: Int, dy: Int) {
        // Raw XY reports don't say which button is held; give them to the one with swipe actions.
        guard let held = mouse.presses.first(where: { actions(for: $0.key).hasDirections }), !held.value.fired else { return }
        let (cid, press) = (held.key, held.value)
        // The first raw XY report after a press holds a large value that isn't movement while
        // held (it follows pointer movement between presses), so drop it.
        if press.skipNextMove {
            press.skipNextMove = false
            return
        }
        press.dx += dx
        press.dy += dy
        let threshold = config.gestureThreshold
        guard abs(press.dx) >= threshold || abs(press.dy) >= threshold else { return }
        let mapped = actions(for: cid)
        let (action, direction): (Action, String) = abs(press.dx) > abs(press.dy)
            ? (press.dx < 0 ? (mapped.left, "left") : (mapped.right, "right"))
            : (press.dy < 0 ? (mapped.up, "up") : (mapped.down, "down"))
        press.fired = true
        guard action != .none else { return }
        if let waveform = config.hapticFeedback, let hapticIndex = mouse.hapticIndex {
            mouse.device.playHaptic(waveform, featureIndex: hapticIndex)
        }
        run(action, "\(Self.label(cid)) \(direction)")
    }

    private func run(_ action: Action, _ trigger: String) {
        if config.verbose { log("\(trigger) -> \(action)") }
        action.perform()
    }
}
