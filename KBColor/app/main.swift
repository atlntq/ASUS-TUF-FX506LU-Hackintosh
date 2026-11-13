// KBColor: menu bar app that sets the keyboard backlight colour through
// KBColor.kext ("Color" property, 0xRRGGBB). The last colour is saved and
// reapplied at launch, so it survives restarts when the app is a login item.
// Also switches the fan mode ("FanMode" property, 0 = Normal, 1 = Turbo,
// 2 = Silent). The menu shows the EC's current mode and live fan speeds, and
// every mode change (menu or Fn+F5) pops up an on-screen HUD. In automatic
// fan control the app picks the mode itself from the CPU temperature. The
// menu also lists temperatures and power draw read from the SMC keys that
// SMCProcessor and SMCBatteryManager publish. Keyboard brightness goes through
// CoreBrightness (the same path as Control Center and Fn+Up/Down, which
// AsusSMC serves), so all three stay in sync. With the nullmoth NVIDIA driver
// loaded, "NVIDIA ile aç" opens chosen apps with libnvdefault.dylib, which
// makes the NVIDIA card their default Metal device (like Optimus); in automatic
// mode the listed apps get it however they are opened.

import AppKit
import IOKit
import IOKit.ps
import ServiceManagement
import UniformTypeIdentifiers

let presets: [(String, UInt32)] = [
    ("Beyaz", 0xFFFFFF), ("Kırmızı", 0xFF0000), ("Turuncu", 0xFF4000),
    ("Sarı", 0xFFB000), ("Yeşil", 0x00FF00), ("Camgöbeği", 0x00FFFF),
    ("Mavi", 0x0000FF), ("Mor", 0x8000FF), ("Pembe", 0xFF00A0),
]

let fanModes: [(String, Int, String)] = [("Sessiz", 2, "leaf.fill"), ("Normal", 0, "fan.fill"), ("Turbo", 1, "flame.fill")]

// kIOMessageServicePropertyChange, sent by the kext after Fn+F5.
let kMsgPropertyChange: UInt32 = 0xE000_0130

func setKext(_ key: String, _ value: NSNumber) -> Bool {
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("KBColor"))
    guard svc != 0 else { return false }
    defer { IOObjectRelease(svc) }
    return IORegistryEntrySetCFProperties(svc, [key: value] as CFDictionary) == KERN_SUCCESS
}

func setKeyboardColor(_ rgb: UInt32) -> Bool { setKext("Color", NSNumber(value: rgb & 0xFFFFFF)) }

func setFanMode(_ mode: Int) -> Bool { setKext("FanMode", NSNumber(value: mode)) }

struct FanState { var mode: Int?; var cpu: Int?; var gpu: Int? }

// Values the kext last published; mode is nil if the kext or SSDT-FANM is
// missing, or the EC is not ready.
func publishedFans() -> FanState {
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("KBColor"))
    guard svc != 0 else { return FanState() }
    defer { IOObjectRelease(svc) }
    func get(_ k: String) -> Int? {
        let v = IORegistryEntryCreateCFProperty(svc, k as CFString, kCFAllocatorDefault, 0)
        return (v?.takeRetainedValue() as? NSNumber)?.intValue
    }
    return FanState(mode: get("FanMode"), cpu: get("CPUFanRPM"), gpu: get("GPUFanRPM"))
}

func readFans() -> FanState {
    guard setKext("ReadFanMode", NSNumber(value: 1)) else { return FanState() }
    return publishedFans()
}

// Reads numeric keys from AppleSMC (struct layout of the SMC user client).
final class SMC {
    struct KeyData {
        var key: UInt32 = 0
        var vers: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
        var plimit: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
        var info: (size: UInt32, type: UInt32, attr: UInt8, pad: (UInt8, UInt8, UInt8)) = (0, 0, 0, (0, 0, 0))
        var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }
    var conn: io_connect_t = 0

    init() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return }
        defer { IOObjectRelease(svc) }
        if IOServiceOpen(svc, mach_task_self_, 0, &conn) != KERN_SUCCESS { conn = 0 }
    }

    func call(_ input: KeyData) -> KeyData? {
        var i = input, o = KeyData(), n = MemoryLayout<KeyData>.size
        let r = IOConnectCallStructMethod(conn, 2, &i, MemoryLayout<KeyData>.size, &o, &n)
        return r == KERN_SUCCESS && o.result == 0 ? o : nil
    }

    // nil if the key is missing or of a type not handled here.
    func value(_ key: String) -> Double? {
        guard conn != 0 else { return nil }
        var q = KeyData()
        q.key = key.utf8.reduce(0) { $0 << 8 | UInt32($1) }
        q.data8 = 9  // key info
        guard let info = call(q) else { return nil }
        q.info = info.info
        q.data8 = 5  // read
        guard let v = call(q) else { return nil }
        let b = withUnsafeBytes(of: v.bytes) { Array($0.prefix(4)) }
        let be16 = UInt16(b[0]) << 8 | UInt16(b[1])
        switch (info.info.type, info.info.size) {
        case (0x7370_3738, 2): return Double(Int16(bitPattern: be16)) / 256  // sp78
        case (0x7370_3936, 2): return Double(Int16(bitPattern: be16)) / 64   // sp96
        case (0x7369_3136, 2): return Double(Int16(bitPattern: be16))        // si16
        case (0x7569_3136, 2): return Double(be16)                           // ui16
        case (0x666C_7420, 4):                                               // flt, little endian
            return Double(Float(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24))
        default: return nil
        }
    }

}

func nvidiaPresent() -> Bool {
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("NVAccel"))
    guard svc != 0 else { return false }
    IOObjectRelease(svc)
    return true
}

// NVIDIA GPU temperature published by the nullmoth driver (NVAccel's
// PerformanceStatistics). nil when the driver is not loaded, e.g. with the
// EFI that turns the dGPU off.
func nvidiaTemperature() -> Double? {
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("NVAccel"))
    guard svc != 0 else { return nil }
    defer { IOObjectRelease(svc) }
    let v = IORegistryEntryCreateCFProperty(svc, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)
    guard let stats = v?.takeRetainedValue() as? [String: Any],
          let t = (stats["Temperature(C)"] as? NSNumber)?.doubleValue, t > 0 else { return nil }
    return t
}

// CPU sensors, sampled in one place at a steady rate. Every read of an
// SMCProcessor key makes the kext recompute power from the RAPL energy
// counters (at most every 100 ms), but its per-core threads refresh those
// counters only every 500 ms. Reads at uneven intervals, such as from several
// timers, then alternate between 0 W (no new counter value since the last
// recompute) and an inflated value (500 ms of energy over a short interval).
// So the CPU keys are read only here, once a second, and power is averaged
// over the last few samples to even out the 500 ms granularity.
final class CPUSensors {
    static let powerKeys = ["PCPR", "PCPC", "PCPG"]
    static let window = 4
    let smc: SMC
    private(set) var package: Double?
    private(set) var cores: [Double] = []
    private var history: [String: [Double]] = [:]

    init(_ smc: SMC) { self.smc = smc }

    func sample() {
        package = smc.value("TC0P")
        cores = (1...4).compactMap { smc.value("TC\($0)C") }
        for k in Self.powerKeys {
            guard let v = smc.value(k) else { history[k] = nil; continue }
            history[k] = Array((history[k, default: []] + [v]).suffix(Self.window))
        }
    }

    func power(_ key: String) -> Double? {
        guard let h = history[key], !h.isEmpty else { return nil }
        return h.reduce(0, +) / Double(h.count)
    }
}

// Menu rows for the "Sensörler" section.
func sensorTitles(_ cpu: CPUSensors, _ smc: SMC) -> [String] {
    func w(_ v: Double?) -> String { v.map { String(format: "%.1f W", $0) } ?? "—" }
    func c(_ v: Double?) -> String { v.map { String(format: "%.0f °C", $0) } ?? "—" }
    let cores = cpu.cores
    var rows = ["CPU paketi: \(c(cpu.package))"]
    if !cores.isEmpty { rows.append("Çekirdekler: " + cores.map { String(format: "%.0f", $0) }.joined(separator: " / ") + " °C") }
    rows.append("CPU gücü: \(w(cpu.power("PCPR")))")
    rows.append("Çekirdek: \(w(cpu.power("PCPC")))  ·  iGPU: \(w(cpu.power("PCPG")))")
    // Only when the NVIDIA driver is loaded, so the row count stays the same
    // while the menu is open (the driver does not come and go at runtime).
    if nvidiaPresent() {
        rows.append("NVIDIA GPU: \(c(nvidiaTemperature()))")
    }
    if let ma = smc.value("B0AC"), let mv = smc.value("B0AV") {
        let watts = abs(ma * mv) / 1_000_000
        let time = batteryMinutes().map { m in
            m.toEmpty.map { " · \(hm($0)) kaldı" } ?? m.toFull.map { " · dolmasına \(hm($0))" } ?? ""
        } ?? ""
        rows.append(ma < 0 ? String(format: "Pil: %.1f W harcanıyor", watts) + time
                    : ma > 0 ? String(format: "Pil: şarj oluyor (%.1f W)", watts) + time : "Pil: adaptörde")
    }
    return rows
}

func hm(_ minutes: Int) -> String { String(format: "%d:%02d", minutes / 60, minutes % 60) }

// macOS's own estimate of the minutes until the battery is empty (on battery)
// or full (charging), the same figures `pmset -g batt` prints. A value is nil
// while macOS is still calculating it (-1) or when it does not apply.
func batteryMinutes() -> (toEmpty: Int?, toFull: Int?)? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for ps in list {
        guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
              d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
        func minutes(_ key: String) -> Int? { (d[key] as? Int).flatMap { $0 > 0 ? $0 : nil } }
        let charging = d[kIOPSIsChargingKey] as? Bool ?? false
        return (charging ? nil : minutes(kIOPSTimeToEmptyKey), charging ? minutes(kIOPSTimeToFullChargeKey) : nil)
    }
    return nil
}

// Automatic fan control: Silent below `low`, Turbo from `high`, Normal in
// between. Stepping down needs the temperature `hysteresis` degrees under the
// threshold, so the mode does not flap around it.
let hysteresis = 5.0

func autoMode(current: Int, temp: Double, low: Int, high: Int) -> Int {
    let lo = Double(low), hi = Double(high)
    switch current {
    case 1:  // Turbo
        if temp > hi - hysteresis { return 1 }
        return temp > lo - hysteresis ? 0 : 2
    case 0:  // Normal
        if temp >= hi { return 1 }
        return temp > lo - hysteresis ? 0 : 2
    default:  // Silent
        if temp >= hi { return 1 }
        return temp >= lo ? 0 : 2
    }
}

let lowChoices = [45, 50, 55, 60, 65, 70]
let highChoices = [70, 75, 80, 85, 90]

func rpmTitle(_ name: String, _ rpm: Int?) -> String {
    guard let rpm else { return "\(name): —" }
    return rpm == 0 ? "\(name): duruyor" : "\(name): \(rpm) RPM"
}

// A small panel in the style of the volume / brightness HUD.
final class HUD {
    let panel: NSPanel
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    let sub = NSTextField(labelWithString: "")
    let dots = NSStackView()
    var hide: DispatchWorkItem?

    init() {
        let size = NSSize(width: 200, height: 200)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 18
        bg.layer?.masksToBounds = true
        panel.contentView = bg

        icon.symbolConfiguration = .init(pointSize: 72, weight: .regular)
        icon.contentTintColor = .labelColor
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = .secondaryLabelColor
        sub.alignment = .center
        dots.orientation = .horizontal
        dots.spacing = 6
        for _ in fanModes {
            let d = NSView()
            d.wantsLayer = true
            d.layer?.cornerRadius = 3
            d.translatesAutoresizingMaskIntoConstraints = false
            d.widthAnchor.constraint(equalToConstant: 40).isActive = true
            d.heightAnchor.constraint(equalToConstant: 6).isActive = true
            dots.addArrangedSubview(d)
        }
        let text = NSStackView(views: [label, sub])
        text.orientation = .vertical
        text.spacing = 2
        let stack = NSStackView(views: [icon, text, dots])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
        ])
    }

    func show(mode: Int, auto: Bool) {
        guard let i = fanModes.firstIndex(where: { $0.1 == mode }) else { return }
        icon.image = NSImage(systemSymbolName: fanModes[i].2, accessibilityDescription: fanModes[i].0)
        label.stringValue = "Fan modu: \(fanModes[i].0)"
        sub.stringValue = auto ? "Otomatik" : "Manuel"
        for (j, d) in dots.arrangedSubviews.enumerated() {
            d.layer?.backgroundColor = (j <= i ? NSColor.labelColor : NSColor.tertiaryLabelColor).cgColor
        }
        if let screen = NSScreen.main {
            let f = screen.frame, s = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: f.midX - s.width / 2, y: f.minY + f.height * 0.14))
        }
        hide?.cancel()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        let w = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ c in
                c.duration = 0.4
                self?.panel.animator().alphaValue = 0
            }, completionHandler: { self?.panel.orderOut(nil) })
        }
        hide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }
}

// Private CoreBrightness KeyboardBrightnessClient, looked up at run time.
final class KeyboardBrightness {
    typealias Get = @convention(c) (AnyObject, Selector, UInt64) -> Float
    typealias Set = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
    let getSel = NSSelectorFromString("brightnessForKeyboard:")
    let setSel = NSSelectorFromString("setBrightness:forKeyboard:")
    var client: NSObject?
    var id: UInt64 = 0

    init() {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW) != nil,
              let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return }
        let c = cls.init()
        guard c.responds(to: getSel), c.responds(to: setSel),
              let ids = c.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue() as? [NSNumber],
              let first = ids.first else { return }
        client = c
        id = first.uint64Value
    }

    // 0...1, nil if no keyboard backlight was found.
    var level: Float? {
        guard let c = client else { return nil }
        return unsafeBitCast(c.method(for: getSel), to: Get.self)(c, getSel, id)
    }

    func set(_ v: Float) -> Bool {
        guard let c = client else { return false }
        return unsafeBitCast(c.method(for: setSel), to: Set.self)(c, setSel, max(0, min(1, v)), id)
    }
}

func nsColor(_ rgb: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
}

func swatch(_ rgb: UInt32) -> NSImage {
    NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
        let p = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
        nsColor(rgb).setFill(); p.fill()
        NSColor.secondaryLabelColor.setStroke(); p.lineWidth = 0.5; p.stroke()
        return true
    }
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var titleTimer: Timer?
    let menu = NSMenu()
    var pending: UInt32?
    var timer: Timer?
    let hud = HUD()
    var port: IONotificationPortRef?
    var interest: io_object_t = 0
    var liveItems: [NSMenuItem] = []
    let kb = KeyboardBrightness()
    let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    var pendingLevel: Float?
    var levelTimer: Timer?
    var liveTimer: Timer?
    let smc = SMC()
    lazy var cpu = CPUSensors(smc)
    var autoTimer: Timer?
    var avgTemp: Double?
    var lastAutoChange = Date.distantPast

    var fanAuto: Bool {
        get { UserDefaults.standard.bool(forKey: "fanAuto") }
        set { UserDefaults.standard.set(newValue, forKey: "fanAuto") }
    }
    var autoLow: Int {
        get { UserDefaults.standard.object(forKey: "autoLow") as? Int ?? 60 }
        set { UserDefaults.standard.set(newValue, forKey: "autoLow") }
    }
    var autoHigh: Int {
        get { UserDefaults.standard.object(forKey: "autoHigh") as? Int ?? 80 }
        set { UserDefaults.standard.set(newValue, forKey: "autoHigh") }
    }

    // Bundle paths of the apps listed under "NVIDIA ile aç".
    var nvApps: [String] {
        get { UserDefaults.standard.stringArray(forKey: "nvApps") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "nvApps") }
    }
    var nvAuto: Bool {
        get { UserDefaults.standard.bool(forKey: "nvAuto") }
        set { UserDefaults.standard.set(newValue, forKey: "nvAuto") }
    }

    var current: UInt32 {
        get { UInt32(UserDefaults.standard.integer(forKey: "color")) }
        set { UserDefaults.standard.set(Int(newValue), forKey: "color") }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        // Until a colour is picked here, keep the one set in Windows.
        let saved = UserDefaults.standard.object(forKey: "color") != nil
        startTitle()
        menu.delegate = self
        item.menu = menu
        if saved { _ = setKeyboardColor(current) }
        watchKext()
        if fanAuto { startAuto() }
        applyNvEnv()
        applyVersionCompat()
    }

    // NullMoth 2.9 reads the macOS version with kern.osproductversion and creates no Metal device below 15. An app built
    // with a pre-11 SDK is told "10.16" (SYSTEM_VERSION_COMPAT), so it is refused, and the refusal crashes it inside
    // Metal as soon as anything enumerates GPUs (IORegistryExplorer 2.1, VideoProc's bundled ffmpeg). With the variable
    // at 0 in launchd, apps started from now on see the real version. It is left set when KBColor quits: unsetting it
    // would bring the crashes back for every app opened afterwards. Without the NVIDIA driver nothing is changed.
    func applyVersionCompat() {
        guard nvidiaPresent() else { return }
        launchctl(["setenv", "SYSTEM_VERSION_COMPAT", "0"])
    }

    func applicationWillTerminate(_ n: Notification) {
        launchctl(["unsetenv", "DYLD_INSERT_LIBRARIES"])
        launchctl(["unsetenv", "NVDEFAULT_APPS"])
    }

    // Samples the CPU sensors once a second (see CPUSensors) and shows the
    // package temperature in the menu bar; the keyboard symbol is the
    // fallback when the SMC key is missing.
    func startTitle() {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.cpu.sample()
            self?.updateTitle()
        }
        RunLoop.main.add(t, forMode: .common)
        titleTimer = t
        cpu.sample()
        updateTitle()
    }

    func updateTitle() {
        guard let b = item.button else { return }
        if let t = cpu.package {
            b.image = nil
            b.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            b.title = String(format: "%.0f°", t)
            b.setAccessibilityLabel(String(format: "CPU %.0f derece", t))
        } else {
            b.title = ""
            b.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "KBColor")
        }
    }

    // Sample every 2 s, smooth the temperature, and change the mode at most
    // every 10 s.
    func startAuto() {
        avgTemp = nil
        autoTimer?.invalidate()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.autoTick() }
        RunLoop.main.add(t, forMode: .common)
        autoTimer = t
        autoTick()
    }

    func stopAuto() {
        autoTimer?.invalidate()
        autoTimer = nil
    }

    func autoTick() {
        guard let t = cpu.package, let mode = publishedFans().mode else { return }
        let avg = avgTemp.map { $0 * 0.7 + t * 0.3 } ?? t
        avgTemp = avg
        let next = autoMode(current: mode, temp: avg, low: autoLow, high: autoHigh)
        guard next != mode, Date().timeIntervalSince(lastAutoChange) >= 10 else { return }
        if setFanMode(next) {
            lastAutoChange = Date()
            hud.show(mode: next, auto: true)
        }
    }

    // Fn+F5 is handled in ACPI; the kext then sends kIOMessageServicePropertyChange.
    func watchKext() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("KBColor"))
        guard svc != 0 else { return }
        defer { IOObjectRelease(svc) }
        port = IONotificationPortCreate(kIOMainPortDefault)
        guard let port else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddInterestNotification(port, svc, kIOGeneralInterest, { ref, _, type, _ in
            guard type == kMsgPropertyChange, let ref else { return }
            // Fn+F5 is a manual choice, so it ends automatic control.
            let app = Unmanaged<App>.fromOpaque(ref).takeUnretainedValue()
            if app.fanAuto { app.fanAuto = false; app.stopAuto() }
            if let mode = publishedFans().mode { app.hud.show(mode: mode, auto: false) }
        }, me, &interest)
    }

    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        let ok = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("KBColor"))
        if ok == 0 {
            m.addItem(withTitle: "KBColor.kext yüklü değil", action: nil, keyEquivalent: "")
            m.addItem(.separator())
        } else { IOObjectRelease(ok) }
        let light = NSMenuItem(title: "Klavye ışığı", action: nil, keyEquivalent: "")
        light.image = NSImage(systemSymbolName: "light.max", accessibilityDescription: nil)
        let lm = NSMenu()
        lm.addItem(withTitle: "Parlaklık", action: nil, keyEquivalent: "")
        let bar = NSMenuItem()
        bar.view = sliderView()
        lm.addItem(bar)
        lm.addItem(.separator())
        lm.addItem(withTitle: "Renk", action: nil, keyEquivalent: "")
        for (name, rgb) in presets {
            let mi = NSMenuItem(title: name, action: #selector(pick(_:)), keyEquivalent: "")
            mi.target = self; mi.tag = Int(rgb); mi.image = swatch(rgb)
            mi.state = UserDefaults.standard.object(forKey: "color") != nil && rgb == current ? .on : .off
            lm.addItem(mi)
        }
        lm.addItem(.separator())
        let custom = NSMenuItem(title: "Özel renk…", action: #selector(openPanel), keyEquivalent: "")
        custom.target = self; custom.image = swatch(current)
        lm.addItem(custom)
        light.submenu = lm
        m.addItem(light)
        m.addItem(.separator())
        m.addItem(withTitle: "Fan kontrolü", action: nil, keyEquivalent: "")
        let fans = readFans()
        for (title, auto) in [("Otomatik", true), ("Manuel", false)] {
            let mi = NSMenuItem(title: title, action: fans.mode == nil ? nil : #selector(pickControl(_:)), keyEquivalent: "")
            mi.target = self; mi.tag = auto ? 1 : 0; mi.indentationLevel = 1
            mi.state = fanAuto == auto ? .on : .off
            m.addItem(mi)
        }
        let limits = NSMenuItem(title: "Otomatik eşikler", action: nil, keyEquivalent: "")
        limits.indentationLevel = 1
        let sub = NSMenu()
        sub.addItem(withTitle: "Normal'e geç", action: nil, keyEquivalent: "")
        for c in lowChoices {
            let mi = NSMenuItem(title: "\(c) °C", action: c < autoHigh ? #selector(pickLow(_:)) : nil, keyEquivalent: "")
            mi.target = self; mi.tag = c; mi.indentationLevel = 1
            mi.state = c == autoLow ? .on : .off
            sub.addItem(mi)
        }
        sub.addItem(.separator())
        sub.addItem(withTitle: "Turbo'ya geç", action: nil, keyEquivalent: "")
        for c in highChoices {
            let mi = NSMenuItem(title: "\(c) °C", action: c > autoLow ? #selector(pickHigh(_:)) : nil, keyEquivalent: "")
            mi.target = self; mi.tag = c; mi.indentationLevel = 1
            mi.state = c == autoHigh ? .on : .off
            sub.addItem(mi)
        }
        limits.submenu = sub
        m.addItem(limits)
        m.addItem(withTitle: "Fan modu", action: nil, keyEquivalent: "")
        for (name, mode, symbol) in fanModes {
            let mi = NSMenuItem(title: name, action: fans.mode == nil ? nil : #selector(pickFan(_:)), keyEquivalent: "")
            mi.target = self; mi.tag = mode; mi.indentationLevel = 1
            mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
            mi.state = mode == fans.mode ? .on : .off
            m.addItem(mi)
        }
        m.addItem(.separator())
        m.addItem(withTitle: "Sensörler", action: nil, keyEquivalent: "")
        liveItems = liveTitles(fans).map { NSMenuItem(title: $0, action: nil, keyEquivalent: "") }
        for mi in liveItems { mi.indentationLevel = 1; m.addItem(mi) }
        m.addItem(.separator())
        if nvidiaPresent() {
            m.addItem(nvidiaMenu())
            m.addItem(.separator())
        }
        let login = NSMenuItem(title: "Açılışta başlat", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        m.addItem(login)
        let quit = NSMenuItem(title: "Çık", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        m.addItem(quit)
    }

    // sun icons on both sides of the slider, as in Control Center.
    func sliderView() -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        let lo = NSImageView(image: NSImage(systemSymbolName: "sun.min", accessibilityDescription: nil)!)
        let hi = NSImageView(image: NSImage(systemSymbolName: "sun.max", accessibilityDescription: nil)!)
        for i in [lo, hi] { i.contentTintColor = .secondaryLabelColor }
        lo.frame = NSRect(x: 18, y: 7, width: 16, height: 16)
        hi.frame = NSRect(x: 210, y: 7, width: 16, height: 16)
        slider.frame = NSRect(x: 40, y: 5, width: 164, height: 20)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(levelChanged(_:))
        if let l = kb.level { slider.floatValue = l; slider.isEnabled = true } else { slider.isEnabled = false }
        for x in [lo, slider, hi] as [NSView] { v.addSubview(x) }
        return v
    }

    // Dragging fires many events; send at most ~20/s.
    @objc func levelChanged(_ s: NSSlider) {
        pendingLevel = s.floatValue
        if levelTimer == nil {
            let t = Timer(timeInterval: 0.05, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.levelTimer = nil
                if let v = self.pendingLevel { self.pendingLevel = nil; if !self.kb.set(v) { NSSound.beep() } }
            }
            RunLoop.main.add(t, forMode: .common)
            levelTimer = t
        }
    }

    func apply(_ rgb: UInt32) {
        current = rgb
        if !setKeyboardColor(rgb) { NSSound.beep() }
    }

    @objc func pick(_ s: NSMenuItem) { apply(UInt32(s.tag)) }

    func liveTitles(_ f: FanState) -> [String] {
        sensorTitles(cpu, smc) + [rpmTitle("CPU fanı", f.cpu), rpmTitle("GPU fanı", f.gpu)]
    }

    // Picking a mode by hand switches to manual control.
    @objc func pickFan(_ s: NSMenuItem) {
        if fanAuto { fanAuto = false; stopAuto() }
        if setFanMode(s.tag) { hud.show(mode: s.tag, auto: false) } else { NSSound.beep() }
    }

    @objc func pickControl(_ s: NSMenuItem) {
        fanAuto = s.tag == 1
        if fanAuto { lastAutoChange = .distantPast; startAuto() } else { stopAuto() }
    }

    @objc func pickLow(_ s: NSMenuItem) { autoLow = s.tag }

    @objc func pickHigh(_ s: NSMenuItem) { autoHigh = s.tag }

    // Refresh the sensor rows once a second while the menu is open.
    func menuWillOpen(_ m: NSMenu) {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let titles = self.liveTitles(readFans())
            guard titles.count == self.liveItems.count else { return }
            for (mi, title) in zip(self.liveItems, titles) { mi.title = title }
        }
        RunLoop.main.add(t, forMode: .common)
        liveTimer = t
    }

    func menuDidClose(_ m: NSMenu) {
        liveTimer?.invalidate()
        liveTimer = nil
    }

    @objc func openPanel() {
        let p = NSColorPanel.shared
        p.showsAlpha = false
        p.color = nsColor(current)
        p.setTarget(self); p.setAction(#selector(panelChanged(_:)))
        p.isContinuous = true
        NSApp.activate(ignoringOtherApps: true)
        p.orderFrontRegardless()
    }

    // The colour wheel fires many events while dragging; send at most ~20/s.
    @objc func panelChanged(_ p: NSColorPanel) {
        guard let c = p.color.usingColorSpace(.sRGB) else { return }
        func b(_ v: CGFloat) -> UInt32 { UInt32((max(0, min(1, v)) * 255).rounded()) }
        pending = b(c.redComponent) << 16 | b(c.greenComponent) << 8 | b(c.blueComponent)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.timer = nil
                if let v = self.pending { self.pending = nil; self.apply(v) }
            }
        }
    }

    func appName(_ path: String) -> String {
        FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
    }

    func appIcon(_ path: String) -> NSImage {
        let i = NSWorkspace.shared.icon(forFile: path)
        i.size = NSSize(width: 16, height: 16)
        return i
    }

    func nvidiaMenu() -> NSMenuItem {
        let top = NSMenuItem(title: "NVIDIA ile aç", action: nil, keyEquivalent: "")
        top.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: nil)
        let sub = NSMenu()
        let auto = NSMenuItem(title: "Otomatik (Dock ve Finder'dan açınca da)", action: #selector(toggleNvAuto), keyEquivalent: "")
        auto.target = self; auto.state = nvAuto ? .on : .off
        sub.addItem(auto)
        sub.addItem(.separator())
        let apps = nvApps.filter { FileManager.default.fileExists(atPath: $0) }
        for path in apps {
            let mi = NSMenuItem(title: appName(path), action: #selector(openNv(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = path; mi.image = appIcon(path)
            sub.addItem(mi)
        }
        if !apps.isEmpty { sub.addItem(.separator()) }
        let add = NSMenuItem(title: "Uygulama ekle…", action: #selector(addNvApp), keyEquivalent: "")
        add.target = self
        sub.addItem(add)
        if !apps.isEmpty {
            let remove = NSMenuItem(title: "Listeden çıkar", action: nil, keyEquivalent: "")
            let rm = NSMenu()
            for path in apps {
                let mi = NSMenuItem(title: appName(path), action: #selector(removeNvApp(_:)), keyEquivalent: "")
                mi.target = self; mi.representedObject = path; mi.image = appIcon(path)
                rm.addItem(mi)
            }
            remove.submenu = rm
            sub.addItem(remove)
        }
        top.submenu = sub
        return top
    }

    @objc func addNvApp() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.allowsMultipleSelection = true
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.message = "NVIDIA ekran kartıyla açılacak uygulamaları seçin"
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK else { return }
        var list = nvApps
        for u in p.urls where !list.contains(u.path) { list.append(u.path) }
        nvApps = list
        applyNvEnv()
    }

    @objc func removeNvApp(_ s: NSMenuItem) {
        guard let path = s.representedObject as? String else { return }
        nvApps = nvApps.filter { $0 != path }
        applyNvEnv()
    }

    @objc func toggleNvAuto() {
        nvAuto.toggle()
        applyNvEnv()
    }

    var nvLibrary: URL? {
        guard let u = Bundle.main.privateFrameworksURL?.appendingPathComponent("libnvdefault.dylib"),
              FileManager.default.fileExists(atPath: u.path) else { return nil }
        return u
    }

    @discardableResult
    func launchctl(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        do { try p.run(); p.waitUntilExit() } catch { return false }
        return p.terminationStatus == 0
    }

    // Automatic mode: launchd passes the library to every app it starts from now on; it acts only in the apps whose
    // bundle IDs are in NVDEFAULT_APPS. Apps already running are not affected. Cleared when the mode is off, the list
    // is empty, the driver is not loaded, or KBColor quits.
    func applyNvEnv() {
        let ids = nvApps.compactMap { Bundle(path: $0)?.bundleIdentifier }
        if nvAuto, !ids.isEmpty, nvidiaPresent(), let lib = nvLibrary {
            launchctl(["setenv", "NVDEFAULT_APPS", ids.joined(separator: ":")])
            launchctl(["setenv", "DYLD_INSERT_LIBRARIES", lib.path])
        } else {
            launchctl(["unsetenv", "DYLD_INSERT_LIBRARIES"])
            launchctl(["unsetenv", "NVDEFAULT_APPS"])
        }
    }

    // The library only takes effect at launch, so a running copy has to quit first.
    @objc func openNv(_ s: NSMenuItem) {
        guard let path = s.representedObject as? String else { return }
        let running = Bundle(path: path)?.bundleIdentifier.map { NSRunningApplication.runningApplications(withBundleIdentifier: $0) } ?? []
        if running.isEmpty { launchNv(path); return }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "\(appName(path)) zaten açık"
        a.informativeText = "NVIDIA ile açmak için uygulamanın kapatılıp yeniden açılması gerekiyor. Kaydedilmemiş işleriniz varsa önce kaydedin."
        a.addButton(withTitle: "Kapat ve NVIDIA ile aç")
        a.addButton(withTitle: "Vazgeç")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        running.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(15)
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] t in
            if running.allSatisfy({ $0.isTerminated }) {
                t.invalidate(); self?.launchNv(path)
            } else if Date() > deadline {
                t.invalidate(); NSSound.beep()
            }
        }
        RunLoop.main.add(t, forMode: .common)
    }

    func launchNv(_ path: String) {
        guard let lib = nvLibrary else { NSSound.beep(); return }
        let c = NSWorkspace.OpenConfiguration()
        c.environment = ["DYLD_INSERT_LIBRARIES": lib.path, "NVDEFAULT_FORCE": "1"]
        c.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: c) { _, err in
            if err != nil { DispatchQueue.main.async { NSSound.beep() } }
        }
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSSound.beep() }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
