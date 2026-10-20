import Foundation
import IOKit.hid

// Minimal HID++ 2.0 client for Logitech devices, reached either through a
// Unifying/Bolt receiver (vendor usage page 0xFF00) or directly over
// Bluetooth (vendor usage page 0xFF43).

enum HIDPP {
    static let shortReport: UInt8 = 0x10
    static let longReport: UInt8 = 0x11
    static let receiverIndex: UInt8 = 0xFF
    static let directIndex: UInt8 = 0xFF

    // HID++ 2.0 feature IDs
    static let featureRoot: UInt16 = 0x0000
    static let featureSet: UInt16 = 0x0001
    static let featureDeviceName: UInt16 = 0x0005
    static let featureWirelessStatus: UInt16 = 0x1D4B
    static let featureReprogControlsV4: UInt16 = 0x1B04
}

final class HIDPPTransport {
    let device: IOHIDDevice
    let isReceiver: Bool
    let maxOutputSize: Int

    /// Called for every input report that is not a reply to a pending request.
    var onNotification: (([UInt8]) -> Void)?

    private let inputBuffer: UnsafeMutablePointer<UInt8>
    private let inputBufferSize = 64
    private var pendingMatch: (([UInt8]) -> Bool)?
    private var pendingReply: [UInt8]?
    private var nextSoftwareID: UInt8 = 1

    init(device: IOHIDDevice) {
        self.device = device
        let usagePage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? 0
        isReceiver = usagePage == 0xFF00
        maxOutputSize = (IOHIDDeviceGetProperty(device, kIOHIDMaxOutputReportSizeKey as CFString) as? Int) ?? 20
        inputBuffer = .allocate(capacity: inputBufferSize)
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, inputBufferSize, { context, _, _, _, _, report, length in
            guard let context else { return }
            let transport = Unmanaged<HIDPPTransport>.fromOpaque(context).takeUnretainedValue()
            transport.handleInput(Array(UnsafeBufferPointer(start: report, count: length)))
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        inputBuffer.deallocate()
    }

    var productName: String {
        (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "Logitech device"
    }

    private func handleInput(_ report: [UInt8]) {
        guard report.count >= 4, report[0] == HIDPP.shortReport || report[0] == HIDPP.longReport else { return }
        if let match = pendingMatch, match(report) {
            pendingReply = report
            pendingMatch = nil
            return
        }
        onNotification?(report)
    }

    @discardableResult
    func send(_ bytes: [UInt8]) -> Bool {
        var report = bytes
        let length = report[0] == HIDPP.shortReport ? 7 : 20
        if report.count < length { report += [UInt8](repeating: 0, count: length - report.count) }
        let result = report.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(report[0]), $0.baseAddress!, length)
        }
        return result == kIOReturnSuccess
    }

    /// Sends a request and pumps the run loop until the matching reply (or an error) arrives.
    private func transact(_ bytes: [UInt8], timeout: TimeInterval, match: @escaping ([UInt8]) -> Bool) -> [UInt8]? {
        pendingReply = nil
        pendingMatch = match
        guard send(bytes) else {
            pendingMatch = nil
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while pendingReply == nil, Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.01, true)
        }
        pendingMatch = nil
        return pendingReply
    }

    struct Failure: Error, CustomStringConvertible {
        let code: UInt8
        var description: String { String(format: "HID++ error 0x%02X", code) }
    }

    /// HID++ 2.0 feature call. Returns the 16 parameter bytes of the reply.
    func call(device index: UInt8, feature: UInt8, function: UInt8, params: [UInt8] = [], timeout: TimeInterval = 1.0) -> Result<[UInt8], Error> {
        let swID = nextSoftwareID
        nextSoftwareID = nextSoftwareID % 15 + 1
        let functionByte = (function << 4) | swID
        let request = [HIDPP.longReport, index, feature, functionByte] + params
        let reply = transact(request, timeout: timeout) { r in
            guard r[1] == index else { return false }
            if r[2] == feature && r[3] == functionByte { return true }
            // HID++ 2.0 error: FF, feature, function, code
            if r[2] == 0xFF && r.count >= 6 && r[3] == feature && r[4] == functionByte { return true }
            // HID++ 1.0 error from the receiver: 8F, subID, address, code
            if r[2] == 0x8F && r.count >= 6 && r[3] == feature && r[4] == functionByte { return true }
            return false
        }
        guard let reply else { return .failure(Failure(code: 0xFE)) }
        if reply[2] == 0xFF || reply[2] == 0x8F { return .failure(Failure(code: reply[5])) }
        return .success(Array(reply[4...]))
    }

    /// HID++ 1.0 register access on the receiver (short reports).
    func setReceiverRegister(_ register: UInt8, _ value: [UInt8]) -> Bool {
        let request = [HIDPP.shortReport, HIDPP.receiverIndex, 0x80, register] + value
        let reply = transact(request, timeout: 1.0) { r in
            r[1] == HIDPP.receiverIndex && (r[2] == 0x80 || r[2] == 0x8F) && r[3] == (r[2] == 0x8F ? 0x80 : register)
        }
        return reply?[2] == 0x80
    }
}

/// A HID++ 2.0 device (one paired slot of a receiver, or a direct Bluetooth connection).
final class HIDPPDevice {
    let transport: HIDPPTransport
    let index: UInt8
    private var featureIndexCache: [UInt16: UInt8] = [:]

    init(transport: HIDPPTransport, index: UInt8) {
        self.transport = transport
        self.index = index
    }

    func call(_ feature: UInt16, function: UInt8, params: [UInt8] = [], timeout: TimeInterval = 1.0) -> Result<[UInt8], Error> {
        guard let featureIndex = featureIndex(feature) else { return .failure(HIDPPTransport.Failure(code: 0xFD)) }
        return transport.call(device: index, feature: featureIndex, function: function, params: params, timeout: timeout)
    }

    /// Returns (major, minor) protocol version, or nil if the device does not answer.
    func ping(timeout: TimeInterval = 0.5) -> (UInt8, UInt8)? {
        guard case let .success(r) = transport.call(device: index, feature: 0, function: 1, params: [0, 0, 0x5A], timeout: timeout) else { return nil }
        return (r[0], r[1])
    }

    func featureIndex(_ feature: UInt16) -> UInt8? {
        if feature == HIDPP.featureRoot { return 0 }
        if let cached = featureIndexCache[feature] { return cached }
        guard case let .success(r) = transport.call(device: index, feature: 0, function: 0, params: [UInt8(feature >> 8), UInt8(feature & 0xFF)]),
              r[0] != 0 else { return nil }
        featureIndexCache[feature] = r[0]
        return r[0]
    }

    func forgetFeatureIndexes() {
        featureIndexCache.removeAll()
    }

    var name: String? {
        guard case let .success(r) = call(HIDPP.featureDeviceName, function: 0) else { return nil }
        let length = Int(r[0])
        var bytes: [UInt8] = []
        while bytes.count < length {
            guard case let .success(chunk) = call(HIDPP.featureDeviceName, function: 1, params: [UInt8(bytes.count)]) else { break }
            bytes += chunk.prefix(length - bytes.count)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    func features() -> [(index: Int, id: UInt16, version: UInt8)] {
        guard case let .success(r) = call(HIDPP.featureSet, function: 0) else { return [] }
        return (1...Int(r[0])).compactMap { i in
            guard case let .success(f) = call(HIDPP.featureSet, function: 1, params: [UInt8(i)]) else { return nil }
            return (i, UInt16(f[0]) << 8 | UInt16(f[1]), f[3])
        }
    }

    // MARK: REPROG_CONTROLS_V4 (0x1B04)

    struct Control {
        let cid: UInt16
        let tid: UInt16
        let flags: UInt8
        let position: UInt8
        let group: UInt8
        let groupMask: UInt8
        let extraFlags: UInt8

        var isDivertable: Bool { flags & 0x20 != 0 }
        var supportsRawXY: Bool { extraFlags & 0x01 != 0 }
    }

    func controls() -> [Control] {
        guard case let .success(r) = call(HIDPP.featureReprogControlsV4, function: 0) else { return [] }
        return (0..<Int(r[0])).compactMap { i in
            guard case let .success(c) = call(HIDPP.featureReprogControlsV4, function: 1, params: [UInt8(i)]) else { return nil }
            return Control(cid: UInt16(c[0]) << 8 | UInt16(c[1]), tid: UInt16(c[2]) << 8 | UInt16(c[3]),
                           flags: c[4], position: c[5], group: c[6], groupMask: c[7], extraFlags: c[8])
        }
    }

    /// Current reporting flags and remap target for a control (getCidReporting).
    func reporting(_ cid: UInt16) -> (flags: UInt8, remap: UInt16)? {
        guard case let .success(r) = call(HIDPP.featureReprogControlsV4, function: 2, params: [UInt8(cid >> 8), UInt8(cid & 0xFF)]) else { return nil }
        return (r[2], UInt16(r[3]) << 8 | UInt16(r[4]))
    }

    /// Diverts a control so presses arrive as HID++ notifications instead of native HID events.
    /// `rawXY` additionally diverts pointer motion while the control is held.
    @discardableResult
    func divert(_ cid: UInt16, rawXY: Bool = false) -> Bool {
        let flags: UInt8 = rawXY ? 0x33 : 0x03 // divert+valid, rawXY+valid
        if case .success = call(HIDPP.featureReprogControlsV4, function: 3, params: [UInt8(cid >> 8), UInt8(cid & 0xFF), flags, 0, 0]) {
            return true
        }
        return false
    }

    @discardableResult
    func undivert(_ cid: UInt16) -> Bool {
        if case .success = call(HIDPP.featureReprogControlsV4, function: 3, params: [UInt8(cid >> 8), UInt8(cid & 0xFF), 0x22, 0, 0]) {
            return true
        }
        return false
    }
}
