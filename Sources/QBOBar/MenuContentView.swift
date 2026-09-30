import QBOCore
import SwiftUI

/// The dropdown shown from the status item.
struct MenuContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    /// Closes the menu bar panel.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.nodeProblem != nil {
                nodeNotice
                Divider()
            } else if let problem = model.runtimeProblem {
                notice(problem, systemImage: "xmark.octagon.fill", tint: .red)
                Divider()
            } else if !model.hasAppKeys {
                setupNotice
                Divider()
            } else if !model.companies.isEmpty, model.accessKeys.isEmpty {
                noClientsNotice
                Divider()
            }
            if model.companies.isEmpty {
                emptyState
            } else {
                companyList
            }
            if let banner = model.banner {
                Divider()
                bannerView(banner)
            }
            Divider()
            footer
        }
        .frame(width: 360)
        .task { await model.refresh() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: model.statusSymbol)
                .foregroundStyle(tint(model.overallHealth))
            VStack(alignment: .leading, spacing: 1) {
                Text("QBO MCP Proxy").font(.headline)
                Text(model.listenerDescription)
                    .font(.caption.monospaced())
                    .foregroundStyle(listenerFailed ? .red : .secondary)
                    .lineLimit(listenerFailed ? 3 : 1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help("The address and port clients connect to")
            }
            Spacer()
            Button {
                openAddCompany()
            } label: {
                Label("Add Company", systemImage: "plus")
            }
            .controlSize(.small)
            .help("Sign in to QuickBooks and pick a company to serve")
        }
        .padding(12)
    }

    private var listenerFailed: Bool {
        if case .failed = model.listener { return true }
        return false
    }

    private var setupNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "key.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Add your Intuit app keys to get started.")
                    .font(.callout)
                Button("Open Settings › Intuit App") { openSettings(tab: .intuit) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(12)
    }

    /// Node.js is the one thing the app can't bundle, so say exactly what's
    /// wrong and offer the two usual ways to fix it.
    private var nodeNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "shippingbox").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.nodeProblem ?? "")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("QBO MCP Proxy runs Intuit's QuickBooks server with Node.js. Install it, and companies start by themselves.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Get Node.js") { NSWorkspace.shared.open(URL(string: "https://nodejs.org/en/download")!) }
                    Button("Copy brew install") { model.copyNodeInstallCommand() }
                    Button("Check Again") { Task { await model.refresh() } }
                }
                .controlSize(.small)
            }
        }
        .padding(12)
    }

    /// Keys are mandatory, so with none there is no way in at all.
    private var noClientsNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "laptopcomputer.and.iphone").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("No clients can connect yet.")
                    .font(.callout)
                Button("Add a client in Settings › Clients") { openSettings(tab: .clients) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "books.vertical")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No companies yet")
                .font(.callout.weight(.medium))
            Text("Use Add Company above to sign in to QuickBooks and pick one.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }

    // MARK: Companies

    @ViewBuilder
    private var companyList: some View {
        let rows = VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.companies.enumerated()), id: \.element.slug) { index, company in
                if index > 0 { Divider().padding(.horizontal, 12) }
                CompanyRowView(company: company, snapshot: model.snapshots[company.slug])
            }
        }
        // See Tunnelbar: a ScrollView only when needed, and with a floor.
        if model.companies.count > 6 {
            ScrollView { rows }.frame(minHeight: 300, maxHeight: 480)
        } else {
            rows
        }
    }

    // MARK: Footer

    private func bannerView(_ banner: AppModel.Banner) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(banner.isError ? .orange : .green)
            Text(banner.text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Button {
                model.banner = nil
            } label: {
                Image(systemName: "xmark").imageScale(.small)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            MenuRow(title: "Connect a Client…", systemImage: "laptopcomputer.and.iphone") {
                openSettings(tab: .clients)
            }
            MenuRow(title: "Settings…", systemImage: "gearshape", shortcut: "⌘,") {
                openSettings(tab: .companies)
            }
            .keyboardShortcut(",")
            Divider().padding(.horizontal, 8).padding(.vertical, 4)
            MenuRow(title: "Quit QBO MCP Proxy", systemImage: "power", shortcut: "⌘Q") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(6)
    }

    private func notice(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    private func openAddCompany() {
        if !model.hasAppKeys {
            openSettings(tab: .intuit)
            return
        }
        Task { await model.beginAuthorization(.add) }
        dismiss()
        openWindow(id: QBOBarApp.addCompanyWindowID)
        bringToFront()
    }

    private func openSettings(tab: SettingsView.Tab) {
        SettingsView.requestedTab = tab
        dismiss()
        openWindow(id: QBOBarApp.settingsWindowID)
        bringToFront()
    }

    private func tint(_ health: AppModel.Health) -> Color {
        switch health {
        case .ok: .green
        case .starting: .secondary
        case .attention: .orange
        case .down: .red
        }
    }
}

/// One company in the menu.
struct CompanyRowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    let company: CompanyConfig
    let snapshot: CompanySnapshot?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(company.name)
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if company.readOnly {
                        Text("read-only")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                    }
                    if company.environment == .sandbox {
                        Text("sandbox")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .background(.yellow.opacity(0.3), in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                Text("/\(company.slug)/")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(detailIsProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                if let cache = cacheLine {
                    Label(cache, systemImage: "internaldrive")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
                if case .needsAuth = snapshot?.status {
                    Button("Reconnect to QuickBooks…") { reconnect() }
                        .controlSize(.small)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 4)
            actions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .opacity(company.enabled ? 1 : 0.55)
    }

    private var actions: some View {
        Menu {
            Button("Reconnect to QuickBooks…") { reconnect() }
            Button("Restart") { model.restart(company.slug) }
                .disabled(!company.enabled)
            Divider()
            Button("Sync Cache Now") { model.syncCache(company.slug) }
                .disabled(!company.enabled)
            Button("Rebuild Cache…") { confirmRebuild() }
                .disabled(!company.enabled)
            Toggle("Read-Only", isOn: Binding(
                get: { company.readOnly }, set: { model.setReadOnly(company.slug, $0) }))
            Toggle("Enabled", isOn: Binding(
                get: { company.enabled }, set: { model.setEnabled(company.slug, $0) }))
            Divider()
            Button("Open Log") {
                dismiss()
                model.openLog(company.slug)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func confirmRebuild() {
        dismiss()
        let alert = NSAlert()
        alert.messageText = "Rebuild the cache for \(company.name)?"
        alert.informativeText = "The cached copy is deleted and fetched again from QuickBooks, all history. "
            + "QuickBooks itself is not touched."
        alert.addButton(withTitle: "Rebuild")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { model.rebuildCache(company.slug) }
    }

    /// e.g. "31,354 cached · synced 12m ago".
    private var cacheLine: String? {
        guard company.enabled, let cache = model.cacheSummaries[company.slug] else { return nil }
        let count = "\(cache.transactions.formatted()) cached"
        switch cache.state {
        case "syncing": return "\(count) · syncing…"
        case "never_synced": return "Cache: first sync pending"
        case "needs_auth": return "\(count) · sync paused until reconnected"
        default:
            let when = cache.lastSuccess.map { "synced \(Format.ago($0))" } ?? "not synced yet"
            return "\(count) · \(when)" + (cache.state == "stale" ? " (stale)" : "")
        }
    }

    private func reconnect() {
        Task { await model.beginAuthorization(.reconnect(slug: company.slug)) }
        dismiss()
        openWindow(id: QBOBarApp.addCompanyWindowID)
        bringToFront()
    }

    private var symbol: String {
        guard company.enabled else { return "pause.circle" }
        switch snapshot?.status {
        case .ready: return "checkmark.circle.fill"
        case .starting, .none: return "circle.dotted"
        case .restarting: return "arrow.clockwise.circle"
        case .needsAuth: return "key.slash"
        case .misconfigured: return "exclamationmark.triangle.fill"
        case .stopped: return "stop.circle"
        }
    }

    private var color: Color {
        guard company.enabled else { return .secondary }
        switch snapshot?.status {
        case .ready: return .green
        case .needsAuth, .misconfigured, .restarting: return .orange
        default: return .secondary
        }
    }

    private var detailIsProblem: Bool {
        switch snapshot?.status {
        case .needsAuth, .misconfigured, .restarting: company.enabled
        default: false
        }
    }

    private var detail: String {
        guard company.enabled else { return "Disabled" }
        guard let snapshot else { return "Starting…" }
        if let problem = snapshot.status.detail { return problem }
        var parts = [snapshot.status.label]
        if snapshot.status.isReady {
            // Streamable HTTP clients hold no connection, so only SSE
            // streams can be counted as "connected".
            if snapshot.sseSessions > 0 { parts.append("\(snapshot.sseSessions) connected") }
            parts.append("\(snapshot.requests) call\(snapshot.requests == 1 ? "" : "s")")
            if snapshot.failures > 0 { parts.append("\(snapshot.failures) failed") }
            if let last = snapshot.lastRequestAt { parts.append("last \(Format.ago(last))") }
        }
        if let warning = snapshot.tokenExpiryWarning { parts.append(warning) }
        return parts.joined(separator: " · ")
    }
}

enum Format {
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<10: return "just now"
        case ..<60: return "\(seconds)s ago"
        case ..<3600: return "\(seconds / 60)m ago"
        case ..<86400: return "\(seconds / 3600)h ago"
        default: return "\(seconds / 86400)d ago"
        }
    }
}

/// A full-width row in the style of a native menu item: icon, title, the
/// shortcut on the right, and a highlight under the pointer.
struct MenuRow: View {
    let title: String
    let systemImage: String
    var shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                    .foregroundStyle(hovering ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                Text(title)
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut)
                        .foregroundStyle(hovering ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
                }
            }
            .foregroundStyle(hovering ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovering ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
