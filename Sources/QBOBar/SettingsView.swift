import AppKit
import QBOCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    enum Tab: Hashable {
        case companies, intuit, clients, general
    }

    /// Set by the menu just before opening the window, so "Add your Intuit
    /// keys" lands on the right tab.
    @MainActor static var requestedTab: Tab?

    @Environment(AppModel.self) private var model
    @State private var tab: Tab

    init(initialTab: Tab = .companies) {
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $tab) {
            CompaniesSettings()
                .tabItem { Label("Companies", systemImage: "building.2") }
                .tag(Tab.companies)
            IntuitSettings()
                .tabItem { Label("Intuit App", systemImage: "key") }
                .tag(Tab.intuit)
            ClientsSettings()
                .tabItem { Label("Clients", systemImage: "laptopcomputer.and.iphone") }
                .tag(Tab.clients)
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
        }
        .padding(20)
        .frame(width: 620)
        .onAppear(perform: takeRequestedTab)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            takeRequestedTab()
        }
    }

    private func takeRequestedTab() {
        if let requested = Self.requestedTab {
            tab = requested
            Self.requestedTab = nil
        }
    }
}

// MARK: - Companies

private struct CompaniesSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var pendingRemoval: CompanyConfig?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.companies.isEmpty {
                Text("No companies yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                List {
                    ForEach(model.companies) { company in
                        CompanySettingsRow(company: company) { pendingRemoval = company }
                    }
                }
                .frame(minHeight: 340)
            }

            HStack {
                Button {
                    Task { await model.beginAuthorization(.add) }
                    openWindow(id: QBOBarApp.addCompanyWindowID)
                    bringToFront()
                } label: {
                    Label("Add Company…", systemImage: "plus")
                }
                .disabled(!model.hasAppKeys)
                Spacer()
                Button("Show Data Folder") { model.revealDataFolder() }
            }
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.name ?? "")?", isPresented: Binding(
                get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { company in
            Button("Remove", role: .destructive) { model.remove(company.slug) }
        } message: { company in
            Text("QBO MCP Proxy stops serving /\(company.slug)/ and deletes its saved token. The QuickBooks company itself is not touched; to serve it again, add it again.")
        }
    }
}

private struct CompanySettingsRow: View {
    @Environment(AppModel.self) private var model
    let company: CompanyConfig
    let onRemove: () -> Void
    @State private var name = ""

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                    .onSubmit { model.rename(company.slug, to: name) }
                Text("/\(company.slug)/ · realm \(company.realmID) · \(company.environment.rawValue)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Toggle("Read-only", isOn: Binding(
                get: { company.readOnly }, set: { model.setReadOnly(company.slug, $0) }))
                .help("Hides create/update/delete tools (QUICKBOOKS_DISABLE_WRITE/UPDATE/DELETE)")
            Toggle("Enabled", isOn: Binding(
                get: { company.enabled }, set: { model.setEnabled(company.slug, $0) }))
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove this company")
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 4)
        .onAppear { name = company.name }
        .onChange(of: company.name) { _, new in name = new }
    }
}

// MARK: - Intuit app

private struct IntuitSettings: View {
    @Environment(AppModel.self) private var model
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var redirectURI = ""
    @State private var message: (text: String, isError: Bool)?
    @State private var saveState: SaveState = .idle

    enum SaveState: Equatable {
        case idle, saving, saved, failed(String)
    }

    private static let dashboard = URL(string: "https://developer.intuit.com/app/developer/dashboard")!

    var body: some View {
        Form {
            Section {
                TextField("Client ID", text: $clientID)
                    .onChange(of: clientID) { if saveState != .saving { saveState = .idle } }
                SecureField("Client Secret", text: $clientSecret)
                    .onChange(of: clientSecret) { if saveState != .saving { saveState = .idle } }
                HStack {
                    Link("Open the Intuit developer dashboard", destination: Self.dashboard)
                        .font(.caption)
                    Spacer()
                    saveStatus
                    Button("Save Keys") { Task { await save() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(saveState == .saving)
                }
            } header: {
                Text("App keys")
            } footer: {
                Text("From your app's Keys & credentials page, using the Production keys. One app serves every company. Stored in the Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Environment", selection: Binding(
                    get: { model.settings.environment },
                    set: { value in Task { _ = await model.updateSettings { $0.environment = value } } })
                ) {
                    Text("Production").tag(IntuitEnvironment.production)
                    Text("Sandbox").tag(IntuitEnvironment.sandbox)
                }
                .help("Applies to companies added from now on")
                HStack {
                    TextField("Redirect URI", text: $redirectURI)
                        .onSubmit { Task { await saveRedirect() } }
                    Button("Copy") {
                        model.copy(redirectURI, confirmation: "Copied the redirect URI")
                    }
                }
            } header: {
                Text("Sign-in")
            } footer: {
                Text("Add this exact Redirect URI to the app in the Intuit dashboard (Keys & credentials › Production › Redirect URIs). Intuit only accepts HTTPS, so it points at a small page that forwards the sign-in back to this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let message {
                Text(message.text)
                    .font(.callout)
                    .foregroundStyle(message.isError ? .orange : .green)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            let keys = model.appKeys()
            clientID = keys?.clientID ?? ""
            clientSecret = keys?.clientSecret ?? ""
            redirectURI = model.settings.redirectURI
        }
    }

    /// Beside the button, where the eye already is: the form's bottom is
    /// usually scrolled out of view.
    @ViewBuilder
    private var saveStatus: some View {
        switch saveState {
        case .idle:
            if hasUnsavedKeys {
                Text("Not saved").font(.caption).foregroundStyle(.secondary)
            }
        case .saving:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("Saving…").font(.caption).foregroundStyle(.secondary)
            }
        case .saved:
            Label("Saved to Keychain", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .transition(.opacity)
        case .failed(let error):
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
                .help(error)
        }
    }

    private var hasUnsavedKeys: Bool {
        let stored = model.appKeys()
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty || !secret.isEmpty else { return false }
        return stored?.clientID != id || stored?.clientSecret != secret
    }

    private func save() async {
        saveState = .saving
        if let error = await model.saveAppKeys(clientID: clientID, clientSecret: clientSecret) {
            saveState = .failed(error)
            return
        }
        await saveRedirect()
        withAnimation { saveState = .saved }
        try? await Task.sleep(for: .seconds(4))
        if saveState == .saved { withAnimation { saveState = .idle } }
    }

    private func saveRedirect() async {
        let trimmed = redirectURI.trimmingCharacters(in: .whitespaces)
        guard trimmed != model.settings.redirectURI else { return }
        guard trimmed.hasPrefix("https://") else {
            message = ("Intuit requires an https:// redirect URI.", true)
            return
        }
        if let error = await model.updateSettings({ $0.redirectURI = trimmed }) { message = (error, true) }
    }
}

// MARK: - Clients

/// Clients are the devices and tools that use the gateway, each identified by
/// its own access key. Every client needs one; there is no key-less access,
/// not even from this Mac.
private struct ClientsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var newName = ""
    @State private var newReadOnly = false
    @State private var created: AccessKey?
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a client for each device or tool that connects, such as a laptop or Claude Code on another Mac. Each gets its own access key, so one can be revoked without touching the others. Copy a client's configuration into it to connect.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                TextField("Client name, e.g. MacBook Pro", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(create)
                Toggle("Read-only", isOn: $newReadOnly)
                    .toggleStyle(.checkbox)
                    .help("The client sees no create, update or delete tools and can't call them")
                Button("Add Client", action: create)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let created {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(created.name) is ready. Copy its configuration into the client:")
                            .font(.callout.weight(.semibold))
                        HStack {
                            Button("Copy claude mcp add Commands") { copyCommands(created) }
                            Button("Copy mcpServers JSON") { copyJSON(created) }
                            Button("Copy Key") { copy(created.secret, "Copied \(created.name)'s key") }
                        }
                        .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            List {
                ForEach(model.accessKeys) { key in
                    ClientRow(
                        key: key,
                        onCopyURLs: { copyURLs(key) },
                        onCopyCommands: { copyCommands(key) },
                        onCopyJSON: { copyJSON(key) },
                        onCopyKey: { copy(key.secret, "Copied \(key.name)'s key") })
                }
            }
            .frame(minHeight: 180)
            .overlay {
                if model.accessKeys.isEmpty {
                    Text("No clients yet. Nothing can connect until you add one.")
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                if let copied {
                    Label(copied, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
                Spacer()
                Text("Keys are sent as Authorization: Bearer <key>, or ?key= for clients that only take a URL.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        newName = ""
        let readOnly = newReadOnly
        newReadOnly = false
        Task { created = await model.createAccessKey(named: name, readOnly: readOnly) }
    }

    private var enabledSlugs: [String] { model.companies.filter(\.enabled).map(\.slug) }

    /// The menu's banner isn't visible from here, so confirm in place.
    private func copy(_ text: String, _ confirmation: String) {
        model.copy(text, confirmation: confirmation)
        withAnimation { copied = confirmation }
        Task {
            try? await Task.sleep(for: .seconds(3))
            if copied == confirmation { withAnimation { copied = nil } }
        }
    }

    private func copyURLs(_ key: AccessKey) {
        copy(enabledSlugs.map { ClientSnippets.urlWithKey(host: model.clientHost, port: model.port, slug: $0, key: key.secret) }
                .joined(separator: "\n"),
             "Copied \(enabledSlugs.count) MCP URL\(enabledSlugs.count == 1 ? "" : "s") with \(key.name)'s key")
    }

    private func copyCommands(_ key: AccessKey) {
        copy(ClientSnippets.claudeCodeAll(host: model.clientHost, port: model.port, slugs: enabledSlugs, key: key.secret),
             "Copied claude mcp add commands for \(key.name)")
    }

    private func copyJSON(_ key: AccessKey) {
        copy(ClientSnippets.mcpServersJSON(host: model.clientHost, port: model.port, slugs: enabledSlugs, key: key.secret),
             "Copied mcpServers JSON for \(key.name)")
    }
}

private struct ClientRow: View {
    @Environment(AppModel.self) private var model
    let key: AccessKey
    let onCopyURLs: () -> Void
    let onCopyCommands: () -> Void
    let onCopyJSON: () -> Void
    let onCopyKey: () -> Void
    @State private var lastUsed: Date?
    @State private var confirmRevoke = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(key.name).font(.body.weight(.medium))
                    if key.readOnly {
                        Text("read-only")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                Text("Added \(key.createdAt.formatted(date: .abbreviated, time: .omitted)) · "
                     + (lastUsed.map { "last connected \(Format.ago($0))" } ?? "not connected since launch")
                     + " · key …\(key.secret.suffix(4))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu("MCP") {
                Button("Copy claude mcp add Commands", action: onCopyCommands)
                Button("Copy mcpServers JSON", action: onCopyJSON)
                Button("Copy MCP URLs with Key", action: onCopyURLs)
                    .help("For clients that take only a URL. The key is in the URL, so prefer the command or JSON where possible.")
                Divider()
                Button("Copy Access Key", action: onCopyKey)
            }
            .fixedSize()
            Button("Revoke", role: .destructive) { confirmRevoke = true }
        }
        .task { lastUsed = await model.lastUsed(key.id) }
        .confirmationDialog("Revoke \(key.name)?", isPresented: $confirmRevoke) {
            Button("Revoke", role: .destructive) { model.revokeAccessKey(key.id) }
        } message: {
            Text("\(key.name) is refused from now on. To reconnect it, add it again and copy the new configuration into it.")
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var port = ""
    @State private var nodePath = ""
    @State private var loginItemStatus = LoginItem.status
    @State private var message: String?

    var body: some View {
        Form {
            Section("Gateway") {
                LabeledContent("Port") {
                    TextField("Port", text: $port)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .onSubmit(savePort)
                }
                LabeledContent("Listening on") {
                    Text(model.listenerDescription)
                        .foregroundStyle(listenerFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                Picker("Accept connections from", selection: Binding(
                    get: { model.settings.networkAccess },
                    set: { value in Task { message = await model.updateSettings { $0.networkAccess = value } } })
                ) {
                    ForEach(NetworkAccess.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .help("The gateway serves plain HTTP. Tailscale encrypts traffic; a shared LAN or Wi-Fi doesn't.")
                Picker("Address in client configs", selection: Binding(
                    get: { model.clientHost }, set: { model.setClientHost($0) })
                ) {
                    ForEach(addresses) { address in
                        Text("\(address.host) — \(address.label)").tag(address.host)
                    }
                }
            }
            Section {
                TextField("Node.js", text: $nodePath, prompt: Text(ServerRuntime.findNode(override: nil) ?? "not found"))
                    .onSubmit(saveNode)
                LabeledContent("Intuit server", value: model.serverVersion.map { String($0.prefix(12)) } ?? "—")
            } header: {
                Text("Runtime")
            } footer: {
                Text("Each company runs Intuit's QuickBooks Online MCP server in its own Node process. Leave Node.js empty to use Homebrew's.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("Open QBO MCP Proxy at login", isOn: Binding(
                    // Registered-but-awaiting-approval still counts as on:
                    // turning it off from there should unregister.
                    get: { loginItemStatus == .enabled || loginItemStatus == .requiresApproval },
                    set: { setLoginItem($0) }))
                    .disabled(!LoginItem.isRunningFromBundle)
                Text(LoginItem.explanation(
                    for: loginItemStatus, bundlePath: LoginItem.bundlePath, isBundled: LoginItem.isRunningFromBundle))
                    .font(.caption)
                    .foregroundStyle(loginItemStatus == .requiresApproval ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(.default, value: loginItemStatus)
                if loginItemStatus == .requiresApproval {
                    Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
                        .controlSize(.small)
                }
            }
            if let message {
                Text(message).foregroundStyle(.orange).font(.callout)
            }
        }
        .formStyle(.grouped)
        // Approval happens in System Settings, outside this window; pick it
        // up when the user comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItemStatus = LoginItem.status
        }
        .onAppear {
            loginItemStatus = LoginItem.status
            port = String(model.settings.port)
            nodePath = model.settings.nodePath ?? ""
        }
    }

    private func setLoginItem(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            message = nil
        } catch {
            message = "\(error)"
        }
        loginItemStatus = LoginItem.status
        // SMAppService can settle a moment after register() returns.
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            loginItemStatus = LoginItem.status
        }
    }

    private var listenerFailed: Bool {
        if case .failed = model.listener { return true }
        return false
    }

    private var addresses: [HostAddresses.Address] {
        // Sample data mustn't show this Mac's real addresses.
        if model.isDemo { return [.init(host: model.clientHost, label: "Bonjour name")] }
        var list = HostAddresses.current()
        list.append(.init(host: "localhost", label: "this Mac only"))
        if !list.contains(where: { $0.host == model.clientHost }) {
            list.insert(.init(host: model.clientHost, label: "saved"), at: 0)
        }
        return list
    }

    private func savePort() {
        guard let value = UInt16(port), value >= 1024 else {
            message = "Pick a port from 1024 to 65535."
            return
        }
        Task { message = await model.updateSettings { $0.port = value } }
    }

    private func saveNode() {
        let trimmed = nodePath.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, !FileManager.default.isExecutableFile(atPath: trimmed) {
            message = "\(trimmed) is not an executable."
            return
        }
        Task { message = await model.updateSettings { $0.nodePath = trimmed.isEmpty ? nil : trimmed } }
    }
}
