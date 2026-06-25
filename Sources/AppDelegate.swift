import AppKit
import CoreVideo

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window:          NSWindow!
    private var videoView:       VideoView!
    private var browser:         EpocCamBrowser!
    private var syphon:          SyphonBridge!
    private var statusItem:      NSTextField!
    private var resolutionMenu:  NSMenu?
    private var activeFormatIndex = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        startPipeline()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Setup

    private func buildMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit EpocCam Viewer",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // Resolution menu (starts empty; populated when sender advertises formats)
        let resMenuItem = NSMenuItem()
        resMenuItem.title = "Resolution"
        mainMenu.addItem(resMenuItem)
        let resMenu = NSMenu(title: "Resolution")
        let placeholder = NSMenuItem(title: "Connecting…", action: nil, keyEquivalent: "")
        placeholder.isEnabled = false
        resMenu.addItem(placeholder)
        resMenuItem.submenu = resMenu
        resolutionMenu = resMenu

        NSApp.mainMenu = mainMenu
    }

    // Called on main thread when the sender advertises its available formats.
    private func populateResolutionMenu(formats: [VideoFormat]) {
        guard let menu = resolutionMenu else { return }
        menu.removeAllItems()
        for fmt in formats {
            let item = NSMenuItem(title: fmt.label,
                                  action: #selector(resolutionSelected(_:)),
                                  keyEquivalent: "")
            item.tag = fmt.index
            item.state = fmt.index == activeFormatIndex ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func resolutionSelected(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx != activeFormatIndex else { return }
        activeFormatIndex = idx
        // Update checkmarks
        resolutionMenu?.items.forEach { $0.state = $0.tag == idx ? .on : .off }
        browser.selectFormat(index: idx)
        NSLog("EpocCam: user selected format index %d", idx)
    }

    private func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: 1280, height: 720)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "EpocCam Viewer"
        window.center()
        window.makeKeyAndOrderFront(nil)

        let content = window.contentView!

        videoView = VideoView(frame: content.bounds)
        videoView.autoresizingMask = [.width, .height]
        content.addSubview(videoView)

        // Status label shown until first frame arrives
        let label = NSTextField(labelWithString: "Searching for EpocCam…")
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        statusItem = label
    }

    // MARK: - Frame-rate meter
    private var fpsWindowStart: CFAbsoluteTime = 0
    private var fpsCount: Int = 0
    private var lastFrameTime: CFAbsoluteTime = 0
    private var frameIntervals: [Double] = []

    private func recordFrame() {
        let now = CFAbsoluteTimeGetCurrent()
        if lastFrameTime > 0 {
            frameIntervals.append(now - lastFrameTime)
        }
        lastFrameTime = now
        fpsCount += 1

        if fpsWindowStart == 0 { fpsWindowStart = now }
        let elapsed = now - fpsWindowStart
        if elapsed >= 5.0 {
            let fps = Double(fpsCount) / elapsed
            if frameIntervals.isEmpty {
                NSLog("EpocCam FPS: %.1f  (%d frames in %.1fs)", fps, fpsCount, elapsed)
            } else {
                let minMs = frameIntervals.min()! * 1000
                let maxMs = frameIntervals.max()! * 1000
                let avgMs = frameIntervals.reduce(0, +) / Double(frameIntervals.count) * 1000
                NSLog("EpocCam FPS: %.1f  interval min=%.1fms avg=%.1fms max=%.1fms  (%d frames in %.1fs)",
                      fps, minMs, avgMs, maxMs, fpsCount, elapsed)
            }
            fpsWindowStart = now
            fpsCount = 0
            frameIntervals.removeAll(keepingCapacity: true)
        }
    }

    private func startPipeline() {
        syphon = SyphonBridge(serverName: "EpocCam")

        browser = EpocCamBrowser()
        browser.onFormats = { [weak self] formats in
            DispatchQueue.main.async { self?.populateResolutionMenu(formats: formats) }
        }
        browser.onStatus = { [weak self] msg in
            // Already dispatched to main thread by Browser
            self?.statusItem.stringValue = msg
        }
        browser.onFrame = { [weak self] pixelBuffer in
            guard let self else { return }
            self.recordFrame()
            // Hide status label on first frame
            DispatchQueue.main.async {
                if self.statusItem.isHidden == false {
                    self.statusItem.isHidden = true
                }
            }
            self.videoView.display(pixelBuffer: pixelBuffer)
            self.syphon.publishPixelBuffer(pixelBuffer)
        }
        browser.start()
    }
}
