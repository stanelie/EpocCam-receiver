import AppKit
import CoreVideo

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window:     NSWindow!
    private var videoView:  VideoView!
    private var browser:    EpocCamBrowser!
    private var syphon:     SyphonBridge!
    private var statusItem: NSTextField!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        startPipeline()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Setup

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit EpocCam Viewer",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
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
