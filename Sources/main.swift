import ApplicationServices
import Foundation

let arguments = CommandLine.arguments.dropFirst()
if arguments.contains("--probe") {
    exit(runProbe())
}
if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    usage: mx4d [--verbose] [--probe]
      (no flags)  run the button daemon
      --verbose   log every button event
      --probe     list connected Logitech devices, features and buttons, then exit
    config: \(Config.path.path)
    """)
    exit(0)
}

var config = Config.load()
if arguments.contains("--verbose") { config.verbose = true }

let driver = Driver(config: config)
driver.start()

// Side buttons need an event tap, which needs Accessibility permission. The gesture
// button's Mission Control/Exposé actions work without it, so keep retrying in the background.
let buttonTap = ButtonTap(universalBackForward: config.universalBackForward, verbose: config.verbose)
buttonTap.onNativeGestureButton = { driver.nativeGestureButtonPressed() }
let axOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
if !AXIsProcessTrustedWithOptions(axOptions) {
    log("Waiting for Accessibility permission (System Settings > Privacy & Security > Accessibility)")
}
func startTap() {
    if buttonTap.start() {
        log("Button tap active")
    } else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: startTap)
    }
}
startTap()

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        driver.stop()
        log("Stopped")
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

log("mx4d running")
CFRunLoopRun()
