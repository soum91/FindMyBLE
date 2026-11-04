import Foundation
import WebKit

/// A real icloud.com page, kept alive in the app. When Apple's servers reject calls made with
/// copied cookies, the same calls are made from inside this page instead, exactly as icloud.com
/// itself makes them. The sign-in screen shows this same web view, and its login is stored on disk.
@MainActor
final class FindMyWebBridge: NSObject, WKNavigationDelegate {
    static let shared = FindMyWebBridge()

    let webView: WKWebView
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.defaultWebpagePreferences.preferredContentMode = .desktop
        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.customUserAgent = FMConst.userAgent
        super.init()
        webView.navigationDelegate = self
        webView.load(URLRequest(url: URL(string: "https://www.icloud.com/find")!))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { release() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { release() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { release() }

    private func release() {
        let w = waiters
        waiters = []
        for c in w { c.resume() }
    }

    /// Makes sure the page is on an icloud.com address so its requests count as same-site.
    private func ready() async {
        if let h = webView.url?.host, h.hasSuffix("icloud.com"), !webView.isLoading { return }
        if !webView.isLoading { webView.load(URLRequest(url: URL(string: "https://www.icloud.com/find")!)) }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c)
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.release() }
        }
    }

    func post(_ url: URL, body: Data?) async throws -> (Data, Int) {
        await ready()
        let js = """
        const r = await fetch(url, {method: 'POST', credentials: 'include',
          headers: {'Content-Type': 'text/plain;charset=UTF-8'}, body: body});
        const t = await r.text();
        return {s: r.status, t: t};
        """
        let args: [String: Any] = ["url": url.absoluteString,
                                   "body": body.map { String(decoding: $0, as: UTF8.self) } ?? NSNull()]
        let res = try await webView.callAsyncJavaScript(js, arguments: args, in: nil, contentWorld: .page)
        guard let d = res as? [String: Any], let s = (d["s"] as? NSNumber)?.intValue else {
            throw FMError.bad("The iCloud page gave no answer.")
        }
        return (Data(((d["t"] as? String) ?? "").utf8), s)
    }

    func clear() {
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { recs in
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: recs) {}
        }
        webView.load(URLRequest(url: URL(string: "https://www.icloud.com/find")!))
    }
}
