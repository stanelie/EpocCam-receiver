import AppKit
import CoreVideo

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var browser: EpocCamBrowser!

    // Per-slot UI + output. Each slot owns its own Syphon server so Millumin sees
    // two distinct sources ("EpocCam A" and "EpocCam B").
    private var syphon:         [CameraSlot: SyphonBridge] = [:]
    private var videoViews:     [CameraSlot: VideoView]    = [:]
    private var statusLabels:   [CameraSlot: NSTextField]  = [:]
    private var statusOverlays: [CameraSlot: NSView]       = [:]
    private var resolutionMenus:[CameraSlot: NSMenu]       = [:]
    private var activeFormatIndex: [CameraSlot: Int] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        for slot in CameraSlot.allCases {
            activeFormatIndex[slot] = UserDefaults.standard.integer(forKey: slot.lastFormatKey)
        }
        buildMenu()
        buildWindow()
        startPipeline()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Menu

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

        // Resolution menu with one submenu per camera slot.
        let resMenuItem = NSMenuItem()
        resMenuItem.title = "Resolution"
        mainMenu.addItem(resMenuItem)
        let resMenu = NSMenu(title: "Resolution")
        for slot in CameraSlot.allCases {
            let slotItem = NSMenuItem(title: "Camera \(slot.label)", action: nil, keyEquivalent: "")
            let slotMenu = NSMenu(title: "Camera \(slot.label)")
            let placeholder = NSMenuItem(title: "Connecting…", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            slotMenu.addItem(placeholder)
            slotItem.submenu = slotMenu
            resMenu.addItem(slotItem)
            resolutionMenus[slot] = slotMenu
        }
        resMenuItem.submenu = resMenu

        // Cameras menu — operator swap control.
        let camMenuItem = NSMenuItem()
        camMenuItem.title = "Cameras"
        mainMenu.addItem(camMenuItem)
        let camMenu = NSMenu(title: "Cameras")
        camMenu.addItem(withTitle: "Swap A ↔ B",
                        action: #selector(swapCameras(_:)),
                        keyEquivalent: "s")
        camMenuItem.submenu = camMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func swapCameras(_ sender: Any?) {
        browser.swapSlots()
    }

    // Called on the main thread when a slot's sender advertises its available formats.
    private func populateResolutionMenu(slot: CameraSlot, formats: [VideoFormat]) {
        guard let menu = resolutionMenus[slot] else { return }
        let active = activeFormatIndex[slot] ?? 0
        menu.removeAllItems()
        for fmt in formats {
            let item = NSMenuItem(title: fmt.label,
                                  action: #selector(resolutionSelected(_:)),
                                  keyEquivalent: "")
            item.tag = fmt.index
            item.representedObject = slot.rawValue
            item.state = fmt.index == active ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func resolutionSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int,
              let slot = CameraSlot(rawValue: raw) else { return }
        let idx = sender.tag
        guard activeFormatIndex[slot] != idx else { return }
        activeFormatIndex[slot] = idx
        resolutionMenus[slot]?.items.forEach { $0.state = $0.tag == idx ? .on : .off }
        browser.selectFormat(slot: slot, index: idx)
        NSLog("EpocCam[%@]: user selected format index %d", slot.label, idx)
    }

    // MARK: - Window

    private func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: 1280, height: 400)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "EpocCam Viewer"
        window.center()
        window.makeKeyAndOrderFront(nil)

        let content = window.contentView!

        // Side-by-side panes: Camera A on the left, Camera B on the right.
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        for slot in CameraSlot.allCases {
            stack.addArrangedSubview(makePane(slot: slot))
        }
    }

    // One pane = a VideoView plus a status pill shown until frames arrive.
    private func makePane(slot: CameraSlot) -> NSView {
        let pane = NSView()
        pane.wantsLayer = true
        pane.layer?.backgroundColor = NSColor.black.cgColor
        pane.translatesAutoresizingMaskIntoConstraints = false

        let videoView = VideoView(frame: .zero)
        videoView.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: pane.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
        ])

        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        pill.layer?.cornerRadius = 10
        pill.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(pill)

        let label = NSTextField(labelWithString: "Searching for camera \(slot.label)…")
        label.textColor = .white
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)

        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: pane.centerXAnchor),
            pill.centerYAnchor.constraint(equalTo: pane.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -10),
        ])

        videoViews[slot]     = videoView
        statusLabels[slot]   = label
        statusOverlays[slot] = pill
        return pane
    }

    // MARK: - Frame-rate meter (per slot)

    private final class FPSMeter {
        var windowStart: CFAbsoluteTime = 0
        var count = 0
    }
    private var meters: [CameraSlot: FPSMeter] = [:]

    private func recordFrame(_ slot: CameraSlot) {
        let m = meters[slot] ?? { let m = FPSMeter(); meters[slot] = m; return m }()
        let now = CFAbsoluteTimeGetCurrent()
        if m.windowStart == 0 { m.windowStart = now }
        m.count += 1
        let elapsed = now - m.windowStart
        if elapsed >= 5.0 {
            NSLog("EpocCam[%@] FPS: %.1f (%d frames in %.1fs)",
                  slot.label, Double(m.count) / elapsed, m.count, elapsed)
            m.windowStart = now
            m.count = 0
        }
    }

    // MARK: - Pipeline

    private func startPipeline() {
        for slot in CameraSlot.allCases {
            syphon[slot] = SyphonBridge(serverName: slot.syphonName)
        }

        browser = EpocCamBrowser()
        browser.onFormats = { [weak self] slot, formats in
            DispatchQueue.main.async { self?.populateResolutionMenu(slot: slot, formats: formats) }
        }
        browser.onStatus = { [weak self] slot, msg in
            // Already dispatched to the main thread by Browser.
            guard let self else { return }
            self.statusLabels[slot]?.stringValue = msg
            self.statusOverlays[slot]?.isHidden = false
            // When a slot loses its feed, wipe the frozen last frame behind the overlay.
            if msg.contains("Searching") || msg.contains("lost") {
                self.videoViews[slot]?.clear()
            }
        }
        browser.onFrame = { [weak self] slot, pixelBuffer in
            guard let self else { return }
            self.recordFrame(slot)
            DispatchQueue.main.async {
                if let overlay = self.statusOverlays[slot], overlay.isHidden == false {
                    overlay.isHidden = true
                }
            }
            self.videoViews[slot]?.display(pixelBuffer: pixelBuffer)
            self.syphon[slot]?.publishPixelBuffer(pixelBuffer)
        }
        browser.start()
    }
}
