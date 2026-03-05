//
//  WebViewModel.swift
//  GeminiDesktop
//
//  Created by alexcding on 2025-12-15.
//

import WebKit
import Combine

/// Handles console.log messages from JavaScript
class ConsoleLogHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? String {
            print("[WebView] \(body)")
        }
    }
}

/// Observable wrapper around WKWebView with Gemini-specific functionality
@Observable
class WebViewModel {

    // MARK: - Constants

    static let geminiURL = URL(string: "https://gemini.google.com/app")!
    static let defaultPageZoom: Double = 1.0

    private static let geminiHost = "gemini.google.com"
    private static let geminiAppPath = "/app"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    private static let minZoom: Double = 0.6
    private static let maxZoom: Double = 1.4

    // MARK: - Public Properties

    let wkWebView: WKWebView
    private(set) var canGoBack: Bool = false
    private(set) var canGoForward: Bool = false
    private(set) var isAtHome: Bool = true

    // MARK: - Private Properties

    private var backObserver: NSKeyValueObservation?
    private var forwardObserver: NSKeyValueObservation?
    private var urlObserver: NSKeyValueObservation?
    private let consoleLogHandler = ConsoleLogHandler()

    // MARK: - Initialization

    init() {
        self.wkWebView = Self.createWebView(consoleLogHandler: consoleLogHandler)
        setupObservers()
        loadHome()
    }

    // MARK: - Navigation

    func loadHome() {
        isAtHome = true
        canGoBack = false
        wkWebView.load(URLRequest(url: Self.geminiURL))
    }

    func goBack() {
        isAtHome = false
        wkWebView.goBack()
    }

    func goForward() {
        wkWebView.goForward()
    }

    func reload() {
        wkWebView.reload()
    }

    func openNewChat() {
        let script = """
        (function() {
            const event = new KeyboardEvent('keydown', {
                key: 'O',
                code: 'KeyO',
                keyCode: 79,
                which: 79,
                shiftKey: true,
                metaKey: true,
                bubbles: true,
                cancelable: true,
                composed: true
            });
            document.activeElement.dispatchEvent(event);
            document.dispatchEvent(event);
        })();
        """
        wkWebView.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: - Image Injection

    /// Maximum base64 size to inject. Prevents the WebView bridge from choking
    /// on massive string evaluations. ~30MB of base64 ≈ ~22MB PNG.
    private static let maxBase64Size = 30_000_000
    private static let maxInjectRetries = 5
    private static let injectRetryDelay: TimeInterval = 0.5

    /// Injects an image directly into the Gemini chat input via JavaScript.
    /// Does NOT use the clipboard — the image data is passed as a named argument
    /// to `callAsyncJavaScript`, which prevents any injection vulnerability.
    func injectImage(_ image: NSImage, retryCount: Int = 0) {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            print("[WebViewModel] Failed to convert image to PNG")
            return
        }

        let base64 = pngData.base64EncodedString()

        // Guard: Cap size to prevent the WebView bridge from hanging on massive payloads.
        guard base64.count < Self.maxBase64Size else {
            print("[WebViewModel] Image too large to inject (\(base64.count) chars, max \(Self.maxBase64Size))")
            return
        }

        // Validate: Ensure base64 contains only safe characters [A-Za-z0-9+/=]
        let safeCharSet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        guard base64.unicodeScalars.allSatisfy({ safeCharSet.contains($0) }) else {
            print("[WebViewModel] Base64 validation failed — unexpected characters detected")
            return
        }

        // External dependency: This relies on the web app accepting synthetic 'paste' events.
        // If the paste feature silently stops working after a web update, check the DOM
        // target selectors and focus state here.
        let script = """
        const binary = atob(imageData);
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) {
            bytes[i] = binary.charCodeAt(i);
        }
        const blob = new Blob([bytes], { type: 'image/png' });
        const file = new File([blob], 'screenshot.png', { type: 'image/png', lastModified: Date.now() });

        const input = document.querySelector('rich-textarea[aria-label="Enter a prompt here"]') ||
                      document.querySelector('[contenteditable="true"]');
        if (!input) { return false; }
        input.focus();

        const dt = new DataTransfer();
        dt.items.add(file);
        const pasteEvent = new ClipboardEvent('paste', {
            bubbles: true,
            cancelable: true,
            clipboardData: dt
        });
        input.dispatchEvent(pasteEvent);
        return true;
        """

        wkWebView.callAsyncJavaScript(
            script,
            arguments: ["imageData": base64],
            in: nil,
            in: .page
        ) { [weak self] result in
            switch result {
            case .success(let value):
                if let success = value as? Bool, success {
                    print("[WebViewModel] Screenshot injected successfully")
                } else if retryCount < Self.maxInjectRetries {
                    print("[WebViewModel] Input not ready, retrying (\(retryCount + 1)/\(Self.maxInjectRetries))...")
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.injectRetryDelay) {
                        self?.injectImage(image, retryCount: retryCount + 1)
                    }
                } else {
                    print("[WebViewModel] Failed to inject screenshot after \(Self.maxInjectRetries) retries")
                }
            case .failure(let error):
                print("[WebViewModel] JS injection error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Zoom

    func zoomIn() {
        let newZoom = min((wkWebView.pageZoom * 100 + 1).rounded() / 100, Self.maxZoom)
        setZoom(newZoom)
    }

    func zoomOut() {
        let newZoom = max((wkWebView.pageZoom * 100 - 1).rounded() / 100, Self.minZoom)
        setZoom(newZoom)
    }

    func resetZoom() {
        setZoom(Self.defaultPageZoom)
    }

    private func setZoom(_ zoom: Double) {
        wkWebView.pageZoom = zoom
        UserDefaults.standard.set(zoom, forKey: UserDefaultsKeys.pageZoom.rawValue)
    }

    // MARK: - Private Setup

    private static func createWebView(consoleLogHandler: ConsoleLogHandler) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        // Add user scripts
        for script in UserScripts.createAllScripts() {
            configuration.userContentController.addUserScript(script)
        }

        // Register console log message handler (debug only)
        #if DEBUG
        configuration.userContentController.add(consoleLogHandler, name: UserScripts.consoleLogHandler)
        #endif

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.customUserAgent = userAgent

        let savedZoom = UserDefaults.standard.double(forKey: UserDefaultsKeys.pageZoom.rawValue)
        webView.pageZoom = savedZoom > 0 ? savedZoom : defaultPageZoom

        return webView
    }

    private func setupObservers() {
        backObserver = wkWebView.observe(\.canGoBack, options: [.new, .initial]) { [weak self] webView, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.canGoBack = !self.isAtHome && webView.canGoBack
            }
        }

        forwardObserver = wkWebView.observe(\.canGoForward, options: [.new, .initial]) { [weak self] webView, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.canGoForward = webView.canGoForward
            }
        }

        urlObserver = wkWebView.observe(\.url, options: .new) { [weak self] webView, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let currentURL = webView.url else { return }

                let isGeminiApp = currentURL.host == Self.geminiHost &&
                                  currentURL.path.hasPrefix(Self.geminiAppPath)

                if isGeminiApp {
                    self.isAtHome = true
                    self.canGoBack = false
                } else {
                    self.isAtHome = false
                    self.canGoBack = webView.canGoBack
                }
            }
        }
    }
}
