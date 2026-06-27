import UIKit
import WebKit
import GoogleSignIn

/// UIKit controller that hosts the WKWebView and reproduces, 1:1, the behaviour of
/// the Android `MainActivity`:
///   - loads https://simplesettleapp.com
///   - custom user-agent suffix ("SimpleSettleiOS")
///   - JS bridge: `AndroidInterface.googleLogin()` / `AndroidInterface.showToast(msg)`
///   - native Google Sign-In -> `onGoogleLoginSuccess(idToken)` injected back to the page
///   - pull-to-refresh + a thin top progress bar
///   - opens tel:/mailto:/external links outside the web view
///   - back/forward via web history (swipe-back gesture, like Android's back button)
final class WebViewController: UIViewController {

    // Matches BASE_URL in MainActivity.kt
    private let baseURL = URL(string: "https://simplesettleapp.com")!

    private var webView: WKWebView!
    private let progressBar = UIProgressView(progressViewStyle: .bar)
    private let refreshControl = UIRefreshControl()
    private var progressObservation: NSKeyValueObservation?

    // MARK: - Lifecycle

    override func loadView() {
        let contentController = WKUserContentController()

        // 1) Register the native message handler. The web page posts to
        //    window.webkit.messageHandlers.AndroidInterface.postMessage({...}).
        contentController.add(self, name: "AndroidInterface")

        // 2) Inject a shim at document start so the EXISTING website code that calls
        //    `AndroidInterface.googleLogin()` / `AndroidInterface.showToast(...)`
        //    keeps working unchanged (those are Android method-call style; iOS uses
        //    postMessage). This makes the same site compatible with both platforms.
        let shim = """
        window.AndroidInterface = {
            googleLogin: function() {
                window.webkit.messageHandlers.AndroidInterface.postMessage({ action: 'googleLogin' });
            },
            showToast: function(message) {
                window.webkit.messageHandlers.AndroidInterface.postMessage({ action: 'showToast', message: message });
            }
        };
        """
        contentController.addUserScript(
            WKUserScript(source: shim, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.allowsInlineMediaPlayback = true
        // domStorageEnabled / databaseEnabled are on by default in WKWebView.

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true   // edge swipe == Android back
        // Append the platform marker the website detects (mirrors "SimpleSettleAndroid").
        webView.customUserAgent = nil // resolved in viewDidLoad after default UA is known

        self.view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        setupUserAgent()
        setupProgressBar()
        setupRefreshControl()

        webView.load(URLRequest(url: baseURL))
    }

    // MARK: - Setup

    private func setupUserAgent() {
        // Read the default UA, then append our suffix (matches MainActivity.kt:112).
        webView.evaluateJavaScript("navigator.userAgent") { [weak self] result, _ in
            guard let self, let ua = result as? String else { return }
            self.webView.customUserAgent = "\(ua) SimpleSettleiOS"
        }
    }

    private func setupProgressBar() {
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.progressTintColor = UIColor(red: 0x62/255, green: 0x00, blue: 0xEE/255, alpha: 1) // #6200EE
        progressBar.trackTintColor = .clear
        progressBar.isHidden = true
        view.addSubview(progressBar)
        NSLayoutConstraint.activate([
            progressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
        ])

        progressObservation = webView.observe(\.estimatedProgress, options: .new) { [weak self] webView, _ in
            guard let self else { return }
            let p = Float(webView.estimatedProgress)
            self.progressBar.setProgress(p, animated: true)
            self.progressBar.isHidden = p >= 1.0
        }
    }

    private func setupRefreshControl() {
        refreshControl.addTarget(self, action: #selector(reloadWeb), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl
    }

    @objc private func reloadWeb() {
        webView.reload()
    }

    // MARK: - Google Sign-In (mirrors setupGoogleSignIn + handleGoogleSignInResult)

    fileprivate func startGoogleSignIn() {
        GIDSignIn.sharedInstance.signIn(withPresenting: self) { [weak self] result, error in
            guard let self else { return }
            if let error {
                self.showToast("Google Sign-In failed: \(error.localizedDescription)")
                return
            }
            // The ID token is what the Android app sends back to the website.
            guard let idToken = result?.user.idToken?.tokenString else {
                self.showToast("Google Sign-In failed: no ID token")
                return
            }
            self.onGoogleLoginSuccess(idToken)
        }
    }

    private func onGoogleLoginSuccess(_ idToken: String) {
        // Escape for safe injection into a JS string literal.
        let escaped = idToken
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        webView.evaluateJavaScript("onGoogleLoginSuccess('\(escaped)')", completionHandler: nil)
    }

    // MARK: - Toast (mirrors AndroidInterface.showToast)

    fileprivate func showToast(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        present(alert, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { alert.dismiss(animated: true) }
    }

    deinit {
        progressObservation?.invalidate()
    }
}

// MARK: - JS -> Native bridge

extension WebViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                              didReceive message: WKScriptMessage) {
        guard message.name == "AndroidInterface",
              let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }

        switch action {
        case "googleLogin":
            startGoogleSignIn()
        case "showToast":
            showToast(body["message"] as? String ?? "")
        default:
            break
        }
    }
}

// MARK: - Navigation (external links, refresh, error handling)

extension WebViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow); return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        // tel: / mailto: / sms: and any non-http(s) scheme -> open with the system,
        // matching shouldOverrideUrlLoading in MainActivity.kt.
        if ["tel", "mailto", "sms", "facetime"].contains(scheme) ||
            (scheme != "http" && scheme != "https" && scheme != "about") {
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshControl.endRefreshing()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        refreshControl.endRefreshing()
        showToast("Connection error")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        refreshControl.endRefreshing()
        showToast("Connection error")
    }
}

// MARK: - UI delegate (target=_blank links + JS alert/confirm)

extension WebViewController: WKUIDelegate {
    // Mirrors setSupportMultipleWindows / javaScriptCanOpenWindowsAutomatically:
    // load target=_blank navigations in the same web view instead of dropping them.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, navigationAction.targetFrame == nil {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}
