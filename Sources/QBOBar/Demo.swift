import AppKit
import QBOCore
import SwiftUI

/// `QBOBar --demo <dir>`: opens the real views in real windows with made-up
/// sample data, screenshots each one with `screencapture`, and exits.
///
/// Unlike `--snapshot` (offscreen rendering, where AppKit controls come out
/// as placeholders) this draws exactly what the app draws. Nothing is started
/// or read: the gateway, the Keychain and the data folder are never touched,
/// so it is safe to run next to the real app, and the pictures can go public.
@MainActor
enum Demo {
    static func run(into directory: URL) -> Never {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            await capture(into: directory)
            exit(0)
        }
        app.run()
        exit(0)
    }

    private static func capture(into directory: URL) async {
        let model = AppModel.preview()

        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            NSApp.appearance = NSAppearance(named: appearance)
            await shoot(menuPanel(MenuContentView().environment(model)), to: directory, name: "menu-\(suffix)")
        }
        NSApp.appearance = NSAppearance(named: .aqua)

        let tabs: [(SettingsView.Tab, String)] = [
            (.companies, "settings-companies"), (.intuit, "settings-intuit"),
            (.clients, "settings-clients"), (.general, "settings-general"),
        ]
        for (tab, name) in tabs {
            await shoot(titled("QBO MCP Proxy Settings", SettingsView(initialTab: tab).environment(model)),
                        to: directory, name: name)
        }

        model.previewAuthorization()
        await shoot(titled("Add a QuickBooks Company", AddCompanyView().environment(model)),
                    to: directory, name: "add-company")
    }

    /// Stands in for the MenuBarExtra panel, which can't be opened from code:
    /// same content, same material and corner radius.
    private static func menuPanel<V: View>(_ content: V) -> NSWindow {
        let hosting = NSHostingView(rootView: content)
        let size = hosting.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        hosting.frame = background.bounds
        hosting.autoresizingMask = [.width, .height]
        background.addSubview(hosting)
        panel.contentView = background
        return panel
    }

    private static func titled<V: View>(_ title: String, _ content: V) -> NSWindow {
        let controller = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(controller.view.fittingSize)
        return window
    }

    private static func shoot(_ window: NSWindow, to directory: URL, name: String) async {
        window.center()
        // Key and active, so title bars and controls draw in their normal,
        // not greyed-out, state.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Let SwiftUI lay out, and grouped forms and materials settle.
        try? await Task.sleep(for: .milliseconds(900))
        let url = directory.appendingPathComponent("\(name).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-l\(window.windowNumber)", url.path]
        try? process.run()
        process.waitUntilExit()
        print(url.path)
        window.orderOut(nil)
    }
}
