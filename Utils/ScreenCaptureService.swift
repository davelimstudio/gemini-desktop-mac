//
//  ScreenCaptureService.swift
//  GeminiDesktop
//
//  Standalone, reusable screen capture component.
//  Provides a ShareX-style overlay for interactive region/window capture.
//  Returns NSImage via completion handler — no knowledge of Gemini or chat.
//

import AppKit

// MARK: - Public API

/// Reusable screen capture service. Call `capture(completion:)` to start
/// an interactive ShareX-style capture session.
///
/// Usage:
/// ```swift
/// ScreenCaptureService.capture { image in
///     guard let image else { return } // user cancelled
///     // Do anything with the image: inject to chat, save to clipboard, write to file, etc.
/// }
/// ```
class ScreenCaptureService {

    /// Retains the active session so it isn't deallocated mid-capture.
    private static var activeSession: CaptureSession?

    /// Starts an interactive screen capture. Completion is called on the main thread
    /// with the captured image, or `nil` if the user cancelled.
    static func capture(completion: @escaping (NSImage?) -> Void) {
        // Cancel any existing session
        activeSession?.cancel()

        let session = CaptureSession { image in
            activeSession = nil
            completion(image)
        }
        activeSession = session
        session.start()
    }
}

// MARK: - CaptureSession

/// Manages the full capture lifecycle: overlays, mouse tracking, window detection, capture.
private class CaptureSession {

    // MARK: - Types

    struct DetectedWindow {
        let windowID: CGWindowID
        let frameCG: CGRect   // CG coordinates (top-left origin)
        let frameNS: NSRect   // NS coordinates (bottom-left origin)
    }

    // MARK: - Constants

    private enum Constants {
        static let overlayAlpha: CGFloat = 0.35
        static let trackingFPS: TimeInterval = 1.0 / 60.0
        static let regionCaptureDelay: TimeInterval = 0.15
        static let minDragSize: CGFloat = 5
        static let highlightBorderWidth: CGFloat = 2
        static let selectionBorderWidth: CGFloat = 1.5
        static let highlightBorderColor = NSColor.systemBlue
        static let selectionBorderColor = NSColor.white
    }

    // MARK: - Properties

    private let completion: (NSImage?) -> Void
    private var overlayWindows: [CaptureOverlayWindow] = []
    private var mouseTrackTimer: Timer?
    private var eventMonitor: Any?

    // State
    private var isDragging = false
    private var dragStart: NSPoint = .zero
    private var currentMouse: NSPoint = .zero
    private var highlightedWindow: DetectedWindow?
    private var lastHighlightedWindow: DetectedWindow?  // preserved across mouseDown for click-capture
    private let myPID = ProcessInfo.processInfo.processIdentifier

    // MARK: - Init

    init(completion: @escaping (NSImage?) -> Void) {
        self.completion = completion
    }

    // MARK: - Lifecycle

    func start() {
        createOverlays()
        startMouseTracking()
        installEventMonitor()
        NSCursor.crosshair.push()
    }

    func cancel() {
        cleanup()
        completion(nil)
    }

    private func cleanup() {
        NSCursor.pop()
        mouseTrackTimer?.invalidate()
        mouseTrackTimer = nil
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll()
    }

    // MARK: - Overlays

    private func createOverlays() {
        for screen in NSScreen.screens {
            let window = CaptureOverlayWindow(screen: screen)
            window.makeKeyAndOrderFront(nil)
            overlayWindows.append(window)
        }
    }

    // MARK: - Mouse Tracking (timer-based for multi-display reliability)

    private func startMouseTracking() {
        mouseTrackTimer = Timer.scheduledTimer(withTimeInterval: Constants.trackingFPS, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let loc = NSEvent.mouseLocation
            self.currentMouse = loc
            if !self.isDragging {
                self.updateHighlightedWindow(at: loc)
            }
            self.updateAllOverlays()
        }
    }

    // MARK: - Event Monitor

    private func installEventMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]
        ) { [weak self] event in
            guard let self = self else { return event }
            switch event.type {
            case .leftMouseDown:
                self.handleMouseDown()
            case .leftMouseDragged:
                self.currentMouse = NSEvent.mouseLocation
                self.updateAllOverlays()
            case .leftMouseUp:
                self.handleMouseUp()
            case .keyDown:
                if event.keyCode == 53 { // Escape
                    self.cancel()
                }
            default:
                break
            }
            return nil // consume all monitored events
        }
    }

    // MARK: - Mouse Handlers

    private func handleMouseDown() {
        lastHighlightedWindow = highlightedWindow
        isDragging = true
        dragStart = NSEvent.mouseLocation
        currentMouse = dragStart
        highlightedWindow = nil
        updateAllOverlays()
    }

    private func handleMouseUp() {
        isDragging = false
        let dragRect = makeDragRect()

        if dragRect.width < Constants.minDragSize && dragRect.height < Constants.minDragSize {
            // Click — capture the window that was highlighted before mouseDown
            if let window = lastHighlightedWindow {
                captureWindow(window)
            } else {
                cancel()
            }
        } else {
            // Drag — capture the selected region
            captureRegion(dragRect)
        }
    }

    // MARK: - Window Detection

    private func updateHighlightedWindow(at nsPoint: NSPoint) {
        let cgPoint = nsPointToCG(nsPoint)

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            highlightedWindow = nil
            return
        }

        for info in windowList {
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  pid != myPID,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0  // Normal window layer only
            else { continue }

            guard let x = boundsDict["X"] as? CGFloat,
                  let y = boundsDict["Y"] as? CGFloat,
                  let w = boundsDict["Width"] as? CGFloat,
                  let h = boundsDict["Height"] as? CGFloat,
                  w > 1, h > 1
            else { continue }

            let frameCG = CGRect(x: x, y: y, width: w, height: h)

            if frameCG.contains(cgPoint) {
                highlightedWindow = DetectedWindow(
                    windowID: windowID,
                    frameCG: frameCG,
                    frameNS: cgRectToNS(frameCG)
                )
                return
            }
        }

        highlightedWindow = nil
    }

    // MARK: - Capture

    private func captureWindow(_ window: DetectedWindow) {
        // CGWindowListCreateImage with .optionIncludingWindow works even with overlay present
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            window.windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            cleanup()
            completion(nil)
            return
        }

        cleanup()
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        completion(image)
    }

    private func captureRegion(_ nsRect: NSRect) {
        let cgRect = nsRectToCG(nsRect)

        // NOTE: Brief delay allows WindowServer to fully clear our dark overlay from the screen.
        // If we get reports of "dark" screenshots, we may need to tune this or switch to a
        // freeze-frame capture (pre-capture the screen before showing overlays).
        cleanup()

        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.regionCaptureDelay) { [self] in
            guard let cgImage = CGWindowListCreateImage(
                cgRect,
                .optionOnScreenOnly,
                kCGNullWindowID,
                .bestResolution
            ) else {
                self.completion(nil)
                return
            }

            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            self.completion(image)
        }
    }

    // MARK: - Overlay Updates

    private func updateAllOverlays() {
        let dragRect = isDragging ? makeDragRect() : nil

        for window in overlayWindows {
            window.overlayView.update(
                highlightFrame: highlightedWindow?.frameNS,
                isDragging: isDragging,
                dragRect: dragRect
            )
        }
    }

    // MARK: - Helpers

    private func makeDragRect() -> NSRect {
        NSRect(
            x: min(dragStart.x, currentMouse.x),
            y: min(dragStart.y, currentMouse.y),
            width: abs(currentMouse.x - dragStart.x),
            height: abs(currentMouse.y - dragStart.y)
        )
    }

    // MARK: - Coordinate Conversion (CG: top-left origin ↔ NS: bottom-left origin)

    private var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    private func nsPointToCG(_ p: NSPoint) -> CGPoint {
        CGPoint(x: p.x, y: primaryScreenHeight - p.y)
    }

    private func cgRectToNS(_ r: CGRect) -> NSRect {
        NSRect(x: r.origin.x, y: primaryScreenHeight - r.origin.y - r.height, width: r.width, height: r.height)
    }

    private func nsRectToCG(_ r: NSRect) -> CGRect {
        CGRect(x: r.origin.x, y: primaryScreenHeight - r.origin.y - r.height, width: r.width, height: r.height)
    }
}

// MARK: - CaptureOverlayWindow

/// Borderless window covering an entire screen for the capture overlay.
private class CaptureOverlayWindow: NSWindow {

    private(set) var overlayView: CaptureOverlayView!

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )

        let view = CaptureOverlayView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            screenFrame: screen.frame
        )
        self.overlayView = view
        self.contentView = view

        isOpaque = false
        hasShadow = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - CaptureOverlayView

/// Draws the dark overlay with clear cutouts for highlighted windows and drag selections.
private class CaptureOverlayView: NSView {

    private let screenFrame: NSRect // global NS coordinates of the screen this view covers
    private var highlightFrame: NSRect?  // global NS coordinates
    private var isDragging = false
    private var dragRect: NSRect?  // global NS coordinates

    init(frame: NSRect, screenFrame: NSRect) {
        self.screenFrame = screenFrame
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(highlightFrame: NSRect?, isDragging: Bool, dragRect: NSRect?) {
        self.highlightFrame = highlightFrame
        self.isDragging = isDragging
        self.dragRect = dragRect
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // 1. Draw dark overlay over entire view
        context.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        context.fill(bounds)

        // 2. Cut out and border the active region
        if isDragging, let rect = dragRect {
            let localRect = globalToLocal(rect)
            drawCutout(context: context, rect: localRect, borderColor: NSColor.white.cgColor, borderWidth: 1.5)
        } else if let frame = highlightFrame {
            let localRect = globalToLocal(frame)
            drawCutout(context: context, rect: localRect, borderColor: NSColor.systemBlue.cgColor, borderWidth: 2)
        }
    }

    private func drawCutout(context: CGContext, rect: NSRect, borderColor: CGColor, borderWidth: CGFloat) {
        // Clear the region to show through to the screen
        context.setBlendMode(.clear)
        context.fill(rect)
        context.setBlendMode(.normal)

        // Draw border
        context.setStrokeColor(borderColor)
        context.setLineWidth(borderWidth)
        context.stroke(rect.insetBy(dx: -borderWidth / 2, dy: -borderWidth / 2))
    }

    /// Convert from global NSScreen coordinates to this view's local coordinates.
    private func globalToLocal(_ rect: NSRect) -> NSRect {
        NSRect(
            x: rect.origin.x - screenFrame.origin.x,
            y: rect.origin.y - screenFrame.origin.y,
            width: rect.width,
            height: rect.height
        )
    }
}
