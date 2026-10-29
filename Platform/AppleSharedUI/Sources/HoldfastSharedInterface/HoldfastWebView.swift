import Foundation
import SwiftUI
import WebKit

/// Shared interface host, not a second Apple UI implementation.
/// Bundle the EXACT SharedUI/dist files; never copy/reimplement the screens in Swift.
/// The handler receives a command JSON object and returns a Reply JSON object.
/// Existing native model/policy checks must run before any mutating response.
@MainActor
public struct HoldfastWebView {
    let assets: URL
    let preview: Bool
    let handle: (Data) async throws -> Data

    public init(assets: URL, preview: Bool = false, handle: @escaping (Data) async throws -> Data) {
        self.assets = assets.standardizedFileURL
        self.preview = preview
        self.handle = handle
    }

    public func makeCoordinator() -> Coordinator { Coordinator(assets: assets, preview: preview, handle: handle) }

    func makeWebView(coordinator: Coordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Explicit preview deliberately has NO native bridge; the shared bundle
        // only activates its in-memory fixture when ?preview=1 is present.
        if !preview { config.userContentController.add(coordinator, name: "holdfast") }
        config.websiteDataStore = preview ? .nonPersistent() : .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = coordinator
        view.uiDelegate = coordinator
        view.allowsBackForwardNavigationGestures = false
        view.loadFileURL(coordinator.indexURL, allowingReadAccessTo: assets)
        return view
    }

    @MainActor
    public final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        let indexURL: URL
        let handle: (Data) async throws -> Data
        var generation = 0
        init(assets: URL, preview: Bool, handle: @escaping (Data) async throws -> Data) {
            var components = URLComponents(url: assets.appendingPathComponent("index.html"), resolvingAgainstBaseURL: false)!
            if preview { components.queryItems = [URLQueryItem(name: "preview", value: "1")] }
            self.indexURL = components.url!
            self.handle = handle
        }
        func trusted(_ url: URL?) -> Bool { url?.absoluteString == indexURL.absoluteString }

        public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "holdfast", message.frameInfo.isMainFrame,
                  trusted(message.frameInfo.request.url), let view = message.webView,
                  trusted(view.url), let body = message.body as? [String: Any],
                  body["version"] as? Int == 1, let id = body["id"] as? String, UUID(uuidString: id) != nil,
                  let command = body["command"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: command), data.count <= 524_288 else { return }
            let epoch = generation
            Task { @MainActor [weak self, weak view] in
                guard let self, let view else { return }
                var reply: [String: Any] = ["version": 1, "id": id]
                do {
                    let response = try await self.handle(data)
                    guard response.count <= 4_194_304,
                          let object = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
                        throw NSError(domain: "Holdfast.SharedInterface", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "The device returned an invalid response."])
                    }
                    reply["ok"] = true; reply["result"] = object
                } catch { reply["ok"] = false; reply["error"] = error.localizedDescription }
                guard epoch == self.generation, self.trusted(view.url),
                      let encoded = try? JSONSerialization.data(withJSONObject: reply, options: [.fragmentsAllowed]),
                      let json = String(data: encoded, encoding: .utf8) else { return }
                // JSON serialization, never interpolated passages/paths/commands.
                _ = try? await view.evaluateJavaScript("window.holdfastReceive?.(\(json))")
            }
        }
        public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.targetFrame?.isMainFrame == true && trusted(action.request.url) ? .allow : .cancel)
        }
        public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { generation += 1 }
        public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                            for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
        public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                            initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                            decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    }
}

#if os(macOS)
extension HoldfastWebView: NSViewRepresentable {
    public func makeNSView(context: Context) -> WKWebView { makeWebView(coordinator: context.coordinator) }
    public func updateNSView(_ view: WKWebView, context: Context) {}
    public static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.generation += 1
        view.configuration.userContentController.removeScriptMessageHandler(forName: "holdfast")
        view.stopLoading()
    }
}
#else
extension HoldfastWebView: UIViewRepresentable {
    public func makeUIView(context: Context) -> WKWebView { makeWebView(coordinator: context.coordinator) }
    public func updateUIView(_ view: WKWebView, context: Context) {}
    public static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.generation += 1
        view.configuration.userContentController.removeScriptMessageHandler(forName: "holdfast")
        view.stopLoading()
    }
}
#endif
