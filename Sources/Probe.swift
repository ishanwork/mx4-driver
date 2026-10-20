import Foundation
import IOKit.hid

func hidppMatching() -> [[String: Any]] {
    [
        [kIOHIDVendorIDKey: 0x046D, kIOHIDPrimaryUsagePageKey: 0xFF00], // Unifying / Bolt receiver
        [kIOHIDVendorIDKey: 0x046D, kIOHIDPrimaryUsagePageKey: 0xFF43], // Bluetooth direct
    ]
}

/// `mx4d --probe`: dump what each connected device reports, for diagnosing new hardware.
func runProbe() -> Int32 {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatchingMultiple(manager, hidppMatching() as CFArray)
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    if openResult != kIOReturnSuccess {
        print(String(format: "IOHIDManagerOpen failed: 0x%08X", openResult))
    }
    CFRunLoopRunInMode(.defaultMode, 0.3, false)

    let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
    let transports = devices.map { HIDPPTransport(device: $0) }
    if transports.isEmpty {
        print("No Logitech HID++ interface found.")
        return 1
    }
    for transport in transports {
        print("Interface: \(transport.productName) (\(transport.isReceiver ? "receiver" : "direct"), max output \(transport.maxOutputSize))")
        transport.onNotification = { r in
            print("  notification: " + r.map { String(format: "%02X", $0) }.joined(separator: " "))
        }
        let indexes: [UInt8] = transport.isReceiver ? Array(1...6) : [HIDPP.directIndex]
        for index in indexes {
            let device = HIDPPDevice(transport: transport, index: index)
            guard let version = device.ping() else { continue }
            print("  Device \(index): \(device.name ?? "?") HID++ \(version.0).\(version.1)")
            for f in device.features() {
                print(String(format: "    feature[%2d] 0x%04X v%d", f.index, f.id, f.version))
            }
            for c in device.controls() {
                let reporting = device.reporting(c.cid)
                print(String(format: "    control cid=0x%04X tid=0x%04X flags=0x%02X extra=0x%02X group=%d gmask=0x%02X reporting=0x%02X remap=0x%04X%@%@",
                             c.cid, c.tid, c.flags, c.extraFlags, c.group, c.groupMask,
                             reporting?.flags ?? 0xFF, reporting?.remap ?? 0xFFFF,
                             c.isDivertable ? " divertable" : "", c.supportsRawXY ? " rawXY" : ""))
            }
        }
    }
    return 0
}
