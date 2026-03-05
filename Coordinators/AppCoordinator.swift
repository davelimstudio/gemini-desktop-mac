//
//  AppCoordinator.swift
//  GeminiDesktop
//
//  Created by alexcding on 2025-12-13.
//

import SwiftUI
import AppKit
import WebKit

extension Notification.Name {
    static let openMainWindow = Notification.Name("openMainWindow")
}

@Observable
class AppCoordinator {
    private var chatBar: ChatBarPanel?
    var webViewModel = WebViewModel()

    var openWindowAction: ((String) -> Void)?

    var canGoBack: Bool { webViewModel.canGoBack }
    var canGoForward: Bool { webViewModel.canGoForward }

    /// Whether the app has Screen Recording permission. Drives UI for screenshot features.
    /// Auto-updates when the app becomes active (e.g., after user grants permission in System Settings).
    private(set) var hasScreenCapturePermission: Bool = false
    private var appActivationObserver: NSObjectProtocol?

    init() {
        // Observe notifications for window opening
        NotificationCenter.default.addObserver(forName: .openMainWindow, object: nil, queue: .main) { [weak self] _ in
            self?.openMainWindow()
        }

        // Check permission on launch
        checkScreenCapturePermission()

        // Re-check permission every time the app becomes active (auto-unlock after user
        // grants permission in System Settings and switches back to the app)
        appActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkScreenCapturePermission()
        }
    }

    func checkScreenCapturePermission() {
        // CGPreflightScreenCaptureAccess() is unreliable in sandboxed apps — it returns
        // false even after permission is granted. Instead, we check if we can see window
        // names of other processes: without Screen Recording permission, macOS strips
        // kCGWindowName from other apps' windows.
        if CGPreflightScreenCaptureAccess() {
            hasScreenCapturePermission = true
            return
        }

        let myPID = ProcessInfo.processInfo.processIdentifier
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            hasScreenCapturePermission = false
            return
        }

        for info in windowList {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid != myPID
            else { continue }

            // If we can read the window name of another process, permission is granted
            if info[kCGWindowName as String] is String {
                hasScreenCapturePermission = true
                return
            }
        }

        hasScreenCapturePermission = false
    }

    // MARK: - Navigation

    func goBack() { webViewModel.goBack() }
    func goForward() { webViewModel.goForward() }
    func goHome() { webViewModel.loadHome() }
    func reload() { webViewModel.reload() }
    func openNewChat() { webViewModel.openNewChat() }

    // MARK: - Zoom

    func zoomIn() { webViewModel.zoomIn() }
    func zoomOut() { webViewModel.zoomOut() }
    func resetZoom() { webViewModel.resetZoom() }

    // MARK: - Chat Bar

    func showChatBar() {
        // Hide main window when showing chat bar
        closeMainWindow()

        if let bar = chatBar {
            // Reuse existing chat bar - reposition to current mouse screen
            repositionChatBarToMouseScreen(bar)
            bar.orderFront(nil)
            bar.makeKeyAndOrderFront(nil)
            bar.checkAndAdjustSize()
            return
        }

        let contentView = ChatBarView(
            webView: webViewModel.wkWebView,
            onExpandToMain: { [weak self] in
                self?.expandToMainWindow()
            }
        )
        let hostingView = NSHostingView(rootView: contentView)
        let bar = ChatBarPanel(contentView: hostingView)

        // Position at bottom center of the screen where mouse is located
        if let screen = NSScreen.screenAtMouseLocation() {
            let origin = screen.bottomCenterPoint(for: bar.frame.size, dockOffset: Constants.dockOffset)
            bar.setFrameOrigin(origin)
        }

        bar.orderFront(nil)
        bar.makeKeyAndOrderFront(nil)
        chatBar = bar
    }

    /// Repositions an existing chat bar to the screen containing the mouse cursor
    private func repositionChatBarToMouseScreen(_ bar: ChatBarPanel) {
        guard let screen = NSScreen.screenAtMouseLocation() else { return }
        let origin = screen.bottomCenterPoint(for: bar.frame.size, dockOffset: Constants.dockOffset)
        bar.setFrameOrigin(origin)
    }

    func hideChatBar() {
        chatBar?.orderOut(nil)
    }

    func closeMainWindow() {
        // Find and hide the main window
        for window in NSApp.windows {
            if window.identifier?.rawValue == Constants.mainWindowIdentifier || window.title == Constants.mainWindowTitle {
                if !(window is NSPanel) {
                    window.orderOut(nil)
                }
            }
        }
    }

    func toggleChatBar() {
        if let bar = chatBar, bar.isVisible {
            hideChatBar()
        } else {
            showChatBar()
        }
    }

    func toggleChatBarNewChat() {
        if let bar = chatBar, bar.isVisible {
            hideChatBar()
        } else {
            showChatBarWithNewChat()
        }
    }

    func showChatBarWithNewChat() {
        showChatBar()
        webViewModel.openNewChat()
        chatBar?.resetToInitialSize()
    }

    // MARK: - Screenshot to Chat

    func screenshotToChat() {
        guard hasScreenCapturePermission else { return }
        // Save current window state for restoration on cancel/failure
        let wasMainWindowVisible = findMainWindow()?.isVisible ?? false
        let wasChatBarVisible = chatBar?.isVisible ?? false

        // Hide all Gemini windows so user can see what they want to capture
        hideAllWindows()

        // Brief delay to let windows fully hide before showing capture overlay
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.screenshotHideDelay) { [weak self] in
            guard let self = self else { return }

            ScreenCaptureService.capture { [weak self] image in
                guard let self = self else { return }

                guard let image = image else {
                    // Defer block: ensures the main chat window always reappears,
                    // even if the capture session throws an error or is cancelled.
                    if wasMainWindowVisible {
                        self.openMainWindow()
                    } else if wasChatBarVisible {
                        self.showChatBar()
                    }
                    return
                }

                // Open main window and inject the screenshot
                self.openMainWindow()

                // Wait for window to become key and WebView to be ready
                DispatchQueue.main.asyncAfter(deadline: .now() + Constants.screenshotInjectDelay) {
                    self.webViewModel.injectImage(image)
                }
            }
        }
    }

    private func hideAllWindows() {
        hideChatBar()
        closeMainWindow()
    }

    // MARK: - Screenshot to Clipboard

    func screenshotToClipboard() {
        guard hasScreenCapturePermission else { return }
        let wasMainWindowVisible = findMainWindow()?.isVisible ?? false
        let wasChatBarVisible = chatBar?.isVisible ?? false

        hideAllWindows()

        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.screenshotHideDelay) { [weak self] in
            guard let self = self else { return }

            ScreenCaptureService.capture { [weak self] image in
                guard let self = self else { return }

                if let image = image {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.writeObjects([image])
                }

                // Restore previous window state
                if wasMainWindowVisible {
                    self.openMainWindow()
                } else if wasChatBarVisible {
                    self.showChatBar()
                }
            }
        }
    }

    func expandToMainWindow() {
        // Capture the screen where the chat bar is located before hiding it
        let targetScreen = chatBar.flatMap { bar -> NSScreen? in
            let center = NSPoint(x: bar.frame.midX, y: bar.frame.midY)
            return NSScreen.screen(containing: center)
        } ?? NSScreen.main

        hideChatBar()
        openMainWindow(on: targetScreen)
    }

    func openMainWindow(on targetScreen: NSScreen? = nil) {
        // Hide chat bar first - WebView can only be in one view hierarchy
        hideChatBar()

        let hideDockIcon = UserDefaults.standard.bool(forKey: UserDefaultsKeys.hideDockIcon.rawValue)
        if !hideDockIcon {
            NSApp.setActivationPolicy(.regular)
        }

        // Find existing main window (may be hidden/suppressed)
        let mainWindow = findMainWindow()

        if let window = mainWindow {
            // Window exists - show it (works for suppressed windows too)
            if let screen = targetScreen {
                centerWindow(window, on: screen)
            }
            window.makeKeyAndOrderFront(nil)
        } else if let openWindowAction = openWindowAction {
            // Window doesn't exist yet - use SwiftUI openWindow to create it
            openWindowAction("main")
            // Position newly created window with retry mechanism
            if let screen = targetScreen {
                centerNewlyCreatedWindow(on: screen)
            }
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    /// Finds the main window by identifier or title
    private func findMainWindow() -> NSWindow? {
        NSApp.windows.first {
            $0.identifier?.rawValue == Constants.mainWindowIdentifier || $0.title == Constants.mainWindowTitle
        }
    }

    /// Centers a window on the specified screen
    private func centerWindow(_ window: NSWindow, on screen: NSScreen) {
        let origin = screen.centerPoint(for: window.frame.size)
        window.setFrameOrigin(origin)
    }

    /// Centers a newly created window on the target screen with retry mechanism
    private func centerNewlyCreatedWindow(on screen: NSScreen, attempt: Int = 1) {
        let maxAttempts = 5
        let retryDelay = 0.05 // 50ms between attempts

        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
            guard let self = self else { return }

            if let window = self.findMainWindow() {
                self.centerWindow(window, on: screen)
            } else if attempt < maxAttempts {
                // Window not found yet, retry
                self.centerNewlyCreatedWindow(on: screen, attempt: attempt + 1)
            }
        }
    }
}


extension AppCoordinator {

    struct Constants {
        static let dockOffset: CGFloat = 50
        static let mainWindowIdentifier = "main"
        static let mainWindowTitle = "Gemini Desktop"
        static let screenshotHideDelay: TimeInterval = 0.3
        static let screenshotInjectDelay: TimeInterval = 0.8
    }

}
