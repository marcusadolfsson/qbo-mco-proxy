import AppKit
import QBOCore
import SwiftUI

/// QBO MCP Proxy: the QuickBooks Online MCP gateway as a menu bar app.
///
/// `LSUIElement` in the bundled Info.plist keeps it out of the Dock, so the
/// status item is the whole interface.
@main
struct QBOBarApp: App {
    @State private var model = AppModel(service: GatewayService(credentials: KeychainCredentialStore()))

    static let settingsWindowID = "settings"
    static let addCompanyWindowID = "add-company"

    /// Terminal commands, handled before any UI exists.
    init() {
        let arguments = CommandLine.arguments
        guard arguments.count > 1 else {
            Self.exitIfAlreadyRunning()
            return
        }

        if let index = arguments.firstIndex(of: "--demo"), arguments.index(after: index) < arguments.endIndex {
            MainActor.assumeIsolated {
                Demo.run(into: URL(fileURLWithPath: arguments[arguments.index(after: index)]))
            }
        }
        if let index = arguments.firstIndex(of: "--snapshot"), arguments.index(after: index) < arguments.endIndex {
            MainActor.assumeIsolated {
                Snapshot.run(into: URL(fileURLWithPath: arguments[arguments.index(after: index)]))
            }
            exit(0)
        }
        if arguments.contains("--serve") {
            // Headless: the gateway without a status item, logging to stderr.
            // For checking a build from a terminal; the app is the normal way.
            Self.serveHeadless()
        }
        if arguments.contains("--status") {
            Self.printStatus()
            exit(0)
        }
        if arguments.contains("--login-item-status") {
            print("bundle:  \(LoginItem.bundlePath)")
            print("status:  \(LoginItem.status.rawValue) — \(LoginItem.explanation)")
            exit(0)
        }
        if arguments.contains("--enable-login-item") || arguments.contains("--disable-login-item") {
            let enable = arguments.contains("--enable-login-item")
            do {
                try LoginItem.setEnabled(enable)
                print("status:  \(LoginItem.status.rawValue) — \(LoginItem.explanation)")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("error: \(error)\n".utf8))
                exit(1)
            }
        }
    }

    /// A second launch (say, from another location) hands over to the copy
    /// already running instead of competing with it. The gateway's own data
    /// lock would stop it serving anyway; this just avoids a second icon.
    private static func exitIfAlreadyRunning() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != getpid() }
        guard let running = others.first else { return }
        running.activate()
        exit(0)
    }

    private static func serveHeadless() -> Never {
        let service = GatewayService(credentials: KeychainCredentialStore(), echoLog: true)
        // Detached: App.init is main-actor isolated, and the run loop below
        // must be free to service the listener.
        Task.detached {
            await service.start()
            while true {
                try? await Task.sleep(for: .seconds(30))
                for snapshot in await service.snapshots() {
                    print("\(snapshot.slug): \(snapshot.status.label) sessions=\(snapshot.sseSessions) "
                          + "requests=\(snapshot.requests) failures=\(snapshot.failures)")
                }
            }
        }
        RunLoop.main.run()
        exit(0)
    }

    /// Reads configuration only; never starts anything or prints a secret.
    private static func printStatus() {
        let paths = Paths.standard
        let settings = GatewaySettings.load(paths)
        let keys = KeychainCredentialStore()
        print("data:        \(paths.base.path)")
        print("port:        \(settings.port)")
        print("redirect:    \(settings.redirectURI)")
        print("intuit app:  \(keys.appKeys()?.isComplete == true ? "configured" : "NOT configured")")
        print("clients:     \(keys.accessKeys().map(\.name).joined(separator: ", "))")
        switch NodeCheck.run(override: settings.nodePath) {
        case .ok(let path, let version): print("node:        \(path) \(version)")
        case .tooOld(let path, let version):
            print("node:        TOO OLD — \(path) is \(version); \(NodeCheck.minimumMajor)+ needed")
        case .missing: print("node:        NOT FOUND (\(NodeCheck.minimumMajor)+ needed)")
        }
        do {
            let runtime = try ServerRuntime.locate(paths: paths, nodeOverride: settings.nodePath)
            print("server:      \(runtime.serverDir.path) @ \(runtime.version)")
        } catch {
            print("server:      \(error)")
        }
        for company in CompanyConfigStore.load(paths) {
            let env = try? EnvFile.read(paths.envFile(company.slug))
            let token = env?[QBOEnv.refreshToken]?.isEmpty == false ? "token saved" : "NO TOKEN"
            print("  /\(company.slug)/  \(company.name)  realm \(company.realmID)  \(company.environment.rawValue)"
                  + "\(company.readOnly ? "  read-only" : "")\(company.enabled ? "" : "  disabled")  \(token)")
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(model)
        } label: {
            Image(systemName: model.statusSymbol)
                .accessibilityLabel("QBO MCP Proxy")
                // The label is always rendered, so it is where the gateway
                // starts: companies come up at login without opening the menu.
                .task { model.start() }
        }
        .menuBarExtraStyle(.window)

        Window("QBO MCP Proxy Settings", id: Self.settingsWindowID) {
            SettingsView()
                .environment(model)
        }
        .windowResizability(.contentSize)

        Window("Add a QuickBooks Company", id: Self.addCompanyWindowID) {
            AddCompanyView()
                .environment(model)
        }
        .windowResizability(.contentSize)
    }
}

/// Brings a window of this accessory app to the front, closing the menu bar
/// panel first so it doesn't sit on top of the window it just opened.
@MainActor
func bringToFront() {
    closeMenuBarPanel()
    NSApp.activate(ignoringOtherApps: true)
}

/// Closes the MenuBarExtra's panel. SwiftUI offers no API for this from
/// outside the panel, so match its window class.
@MainActor
func closeMenuBarPanel() {
    for window in NSApp.windows where window.isVisible
        && String(describing: type(of: window)).contains("MenuBarExtra") {
        window.close()
    }
}
