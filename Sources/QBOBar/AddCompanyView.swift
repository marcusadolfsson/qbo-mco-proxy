import QBOCore
import SwiftUI

/// The sign-in in progress when adding or reconnecting a company.
///
/// Add Company opens QuickBooks in the browser straight away; this window only
/// keeps the user oriented while they sign in, offers the paste fallback, and
/// closes itself once the company is connected (its menu row then says so).
struct AddCompanyView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var pastedURL = ""
    @State private var showPaste = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let flow = model.authorization {
                waiting(flow)
            } else {
                idle
            }
        }
        .padding(24)
        .frame(width: 460)
        .onChange(of: model.lastConnected) { _, company in
            guard company != nil else { return }
            model.lastConnected = nil
            dismissWindow()
        }
    }

    /// Only seen if the window is reopened with nothing in progress, e.g.
    /// restored at launch.
    private var idle: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("No sign-in in progress.")
                .font(.title3.weight(.semibold))
            HStack {
                Button("Close") { dismissWindow() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Sign in with QuickBooks") { Task { await model.beginAuthorization(.add) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.hasAppKeys)
            }
        }
    }

    private func waiting(_ flow: AppModel.Authorization) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if flow.error == nil { ProgressView().controlSize(.small) }
                Text(title(for: flow))
                    .font(.title3.weight(.semibold))
            }
            if let error = flow.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                Text("Finish signing in in your browser and pick the company. This window updates by itself when QuickBooks sends you back.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup("Browser didn't come back to QBO MCP Proxy?", isExpanded: $showPaste) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Copy the whole address from the browser's address bar after signing in, and paste it here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        TextField("https://…?code=…&realmId=…&state=…", text: $pastedURL)
                            .textFieldStyle(.roundedBorder)
                        Button("Use") {
                            let text = pastedURL
                            pastedURL = ""
                            Task { await model.completeWithPastedURL(text) }
                        }
                        .disabled(pastedURL.isEmpty)
                    }
                }
                .padding(.top, 6)
            }
            .font(.callout)

            HStack {
                Button("Cancel") {
                    Task { await model.cancelAuthorization() }
                    dismissWindow()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if flow.error != nil {
                    Button("Try Again") {
                        Task { await model.beginAuthorization(flow.purpose) }
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Open Sign-in Page Again") { model.reopenAuthorizationPage() }
                }
            }
        }
    }

    private func title(for flow: AppModel.Authorization) -> String {
        switch flow.purpose {
        case .add: "Waiting for QuickBooks…"
        case .reconnect(let slug):
            "Reconnecting \(model.companies.first { $0.slug == slug }?.name ?? slug)…"
        }
    }
}
