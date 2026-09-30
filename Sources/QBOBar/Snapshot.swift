import AppKit
import QBOCore
import SwiftUI

/// `QBOBar --snapshot <dir>`: renders the menu and windows with sample data
/// to PNGs, so the UI can be checked without clicking through the menu bar.
/// Sample data only; nothing is started and nothing is read from disk.
@MainActor
enum Snapshot {
    static func run(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = AppModel.preview()
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .light ? "light" : "dark"
            render(MenuContentView(), model: model, scheme: scheme, width: 360,
                   to: directory.appendingPathComponent("menu-\(suffix).png"))
        }
        render(AddCompanyView(), model: model, scheme: .light, width: 460,
               to: directory.appendingPathComponent("add-company.png"))
        model.previewAuthorization()
        render(AddCompanyView(), model: model, scheme: .light, width: 460,
               to: directory.appendingPathComponent("add-company-waiting.png"))
        let noNode = AppModel.preview(empty: true)
        noNode.previewNodeMissing()
        render(MenuContentView(), model: noNode, scheme: .light, width: 360,
               to: directory.appendingPathComponent("menu-node-missing.png"))
        let empty = AppModel.preview(empty: true)
        render(MenuContentView(), model: empty, scheme: .light, width: 360,
               to: directory.appendingPathComponent("menu-empty.png"))
    }

    private static func render<V: View>(_ view: V, model: AppModel, scheme: ColorScheme, width: CGFloat, to url: URL) {
        let content = view
            .environment(model)
            .environment(\.colorScheme, scheme)
            .frame(width: width)
            .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.97))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: url)
        print(url.path)
    }
}

extension AppModel {
    static func preview(empty: Bool = false) -> AppModel {
        let paths = Paths(base: FileManager.default.temporaryDirectory.appendingPathComponent("qbobar-preview"))
        let credentials = MemoryCredentialStore(
            appKeys: IntuitAppKeys(clientID: "AB7kDemoClientID9fX2qLmN4pR8sT1vW6yZ", clientSecret: "demo-secret-demo"))
        let model = AppModel(service: GatewayService(paths: paths, credentials: credentials))
        model.applyPreview(empty: empty)
        return model
    }
}
