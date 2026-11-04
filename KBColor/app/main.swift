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
// AsusSMC serves), so all three stay in sync.

import AppKit
import IOKit
import ServiceManagement

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

// Menu rows for the "Sensörler" section.
func sensorTitles(_ smc: SMC) -> [String] {
    func w(_ v: Double?) -> String { v.map { String(format: "%.1f W", $0) } ?? "—" }
    func c(_ v: Double?) -> String { v.map { String(format: "%.0f °C", $0) } ?? "—" }
    let cores = (1...4).compactMap { smc.value("TC\($0)C") }
    var rows = ["CPU paketi: \(c(smc.value("TC0P")))"]
    if !cores.isEmpty { rows.append("Çekirdekler: " + cores.map { String(format: "%.0f", $0) }.joined(separator: " / ") + " °C") }
    rows.append("CPU gücü: \(w(smc.value("PCPR")))")
    rows.append("Çekirdek: \(w(smc.value("PCPC")))  ·  iGPU: \(w(smc.value("PCPG")))")
    // Only when the NVIDIA driver is loaded, so the row count stays the same
    // while the menu is open (the driver does not come and go at runtime).
    if nvidiaPresent() {
        rows.append("NVIDIA GPU: \(c(nvidiaTemperature()))")
    }
    if let ma = smc.value("B0AC"), let mv = smc.value("B0AV") {
        let watts = abs(ma * mv) / 1_000_000
        rows.append(ma < 0 ? String(format: "Pil: %.1f W harcanıyor", watts)
                    : ma > 0 ? String(format: "Pil: şarj oluyor (%.1f W)", watts) : "Pil: adaptörde")
    }
    return rows
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
    }

    // The menu bar shows the CPU package temperature, updated every 2 s;
    // the keyboard symbol is the fallback when the SMC key is missing.
    func startTitle() {
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.updateTitle() }
        RunLoop.main.add(t, forMode: .common)
        titleTimer = t
        updateTitle()
    }

    func updateTitle() {
        guard let b = item.button else { return }
        if let t = smc.value("TC0P") {
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
        guard let t = smc.value("TC0P"), let mode = publishedFans().mode else { return }
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
        sensorTitles(smc) + [rpmTitle("CPU fanı", f.cpu), rpmTitle("GPU fanı", f.gpu)]
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
