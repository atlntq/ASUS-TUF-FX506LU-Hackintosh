// KBColor: menu bar app that sets the keyboard backlight colour through
// KBColor.kext ("Color" property, 0xRRGGBB). The last colour is saved and
// reapplied at launch, so it survives restarts when the app is a login item.

import AppKit
import IOKit
import ServiceManagement

let presets: [(String, UInt32)] = [
    ("Beyaz", 0xFFFFFF), ("Kırmızı", 0xFF0000), ("Turuncu", 0xFF4000),
    ("Sarı", 0xFFB000), ("Yeşil", 0x00FF00), ("Camgöbeği", 0x00FFFF),
    ("Mavi", 0x0000FF), ("Mor", 0x8000FF), ("Pembe", 0xFF00A0),
]

func setKeyboardColor(_ rgb: UInt32) -> Bool {
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("KBColor"))
    guard svc != 0 else { return false }
    defer { IOObjectRelease(svc) }
    let props = ["Color": NSNumber(value: rgb & 0xFFFFFF)] as CFDictionary
    return IORegistryEntrySetCFProperties(svc, props) == KERN_SUCCESS
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
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    var pending: UInt32?
    var timer: Timer?

    var current: UInt32 {
        get { UInt32(UserDefaults.standard.integer(forKey: "color")) }
        set { UserDefaults.standard.set(Int(newValue), forKey: "color") }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        // Until a colour is picked here, keep the one set in Windows.
        let saved = UserDefaults.standard.object(forKey: "color") != nil
        item.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Klavye rengi")
        menu.delegate = self
        item.menu = menu
        if saved { _ = setKeyboardColor(current) }
    }

    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        let ok = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("KBColor"))
        if ok == 0 {
            m.addItem(withTitle: "KBColor.kext yüklü değil", action: nil, keyEquivalent: "")
            m.addItem(.separator())
        } else { IOObjectRelease(ok) }
        for (name, rgb) in presets {
            let mi = NSMenuItem(title: name, action: #selector(pick(_:)), keyEquivalent: "")
            mi.target = self; mi.tag = Int(rgb); mi.image = swatch(rgb)
            mi.state = UserDefaults.standard.object(forKey: "color") != nil && rgb == current ? .on : .off
            m.addItem(mi)
        }
        m.addItem(.separator())
        let custom = NSMenuItem(title: "Özel renk…", action: #selector(openPanel), keyEquivalent: "")
        custom.target = self; custom.image = swatch(current)
        m.addItem(custom)
        m.addItem(.separator())
        let login = NSMenuItem(title: "Açılışta başlat", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        m.addItem(login)
        let quit = NSMenuItem(title: "Çık", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        m.addItem(quit)
    }

    func apply(_ rgb: UInt32) {
        current = rgb
        if !setKeyboardColor(rgb) { NSSound.beep() }
    }

    @objc func pick(_ s: NSMenuItem) { apply(UInt32(s.tag)) }

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
