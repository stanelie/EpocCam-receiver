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
    private var titleLabels:    [CameraSlot: NSTextField]  = [:]
    private var lightButtons:   [CameraSlot: NSButton]     = [:]
    // What we last *asked* each phone to do. The phone doesn't acknowledge, so this tracks
    // the request, not confirmed hardware state.
    private var torchOn:        [CameraSlot: Bool]         = [:]
    private var resolutionMenus:[CameraSlot: NSMenu]       = [:]
    private var alwaysOnTopItem: NSMenuItem?
    private static let kAlwaysOnTopKey = "EpocCamAlwaysOnTop"
    private var activeFormatIndex: [CameraSlot: Int] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        for slot in CameraSlot.allCases {
            activeFormatIndex[slot] = UserDefaults.standard.integer(forKey: slot.lastFormatKey)
        }
        buildMenu()
        buildWindow()
        setAlwaysOnTop(UserDefaults.standard.bool(forKey: Self.kAlwaysOnTopKey))
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
        appMenu.addItem(withTitle: "About EpocCam Viewer",
                        action: #selector(showAbout(_:)),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
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

        // Window menu — keep the viewer above Millumin while operating it.
        let winMenuItem = NSMenuItem()
        winMenuItem.title = "Window"
        mainMenu.addItem(winMenuItem)
        let winMenu = NSMenu(title: "Window")
        let onTop = NSMenuItem(title: "Always on Top",
                               action: #selector(toggleAlwaysOnTop(_:)),
                               keyEquivalent: "t")
        winMenu.addItem(onTop)
        winMenuItem.submenu = winMenu
        alwaysOnTopItem = onTop

        NSApp.mainMenu = mainMenu
    }

    @objc private func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(string:
            "Dual-camera EpocCam receiver — discovers phones over mDNS and publishes\n" +
            "each as a Syphon source (\"EpocCam A\" / \"EpocCam B\") for Millumin and others.\n\n" +
            "github.com/stanelie/EpocCam-receiver")
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func toggleAlwaysOnTop(_ sender: Any?) {
        setAlwaysOnTop(!UserDefaults.standard.bool(forKey: Self.kAlwaysOnTopKey))
    }

    // Persisted: an operator who wants the viewer pinned over Millumin wants it pinned
    // again next launch, not to rediscover the menu item every show.
    private func setAlwaysOnTop(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.kAlwaysOnTopKey)
        window?.level = on ? .floating : .normal
        alwaysOnTopItem?.state = on ? .on : .off
        NSLog("EpocCam: always on top %@", on ? "ON" : "OFF")
    }

    @objc private func toggleLight(_ sender: NSButton) {
        guard let slot = CameraSlot(rawValue: sender.tag) else { return }
        let on = !(torchOn[slot] ?? false)
        torchOn[slot] = on
        applyLightAppearance(slot)
        browser.setTorch(slot: slot, on: on)
        NSLog("EpocCam[%@]: torch %@ requested", slot.label, on ? "ON" : "OFF")
    }

    private func applyLightAppearance(_ slot: CameraSlot) {
        guard let b = lightButtons[slot] else { return }
        let on = torchOn[slot] ?? false
        b.layer?.backgroundColor = on ? NSColor.systemYellow.withAlphaComponent(0.85).cgColor
                                      : NSColor.black.withAlphaComponent(0.45).cgColor
        b.alphaValue = on ? 1.0 : 0.65
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

        // Title row above the panes: one label per slot ("Camera A — 82%"), same column
        // widths as the video stack below so each title sits above its own pane.
        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.distribution = .fillEqually
        titleRow.spacing = 2
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(titleRow)

        // Side-by-side panes: Camera A on the left, Camera B on the right.
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            titleRow.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            titleRow.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            titleRow.topAnchor.constraint(equalTo: content.topAnchor),
            titleRow.heightAnchor.constraint(equalToConstant: 30),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: titleRow.bottomAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        for slot in CameraSlot.allCases {
            titleRow.addArrangedSubview(makeTitleLabel(slot: slot))
            stack.addArrangedSubview(makePane(slot: slot))
        }

        // Swap button sits across the two title cells rather than inside either one — it acts
        // on both. Added to `content` (not titleRow) so it can straddle the pane boundary; the
        // per-slot labels are centred within their own halves, so they don't collide with it.
        let swap = NSButton(title: "Swap A ↔ B", target: self, action: #selector(swapCameras(_:)))
        // Borderless over its own layer rather than a stock bezel: .rounded has a fixed
        // intrinsic height and simply ignores a height constraint, so it can't be made to
        // match the title bar.
        swap.isBordered = false
        swap.wantsLayer = true
        swap.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        swap.contentTintColor = .white
        swap.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        swap.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(swap)
        NSLayoutConstraint.activate([
            swap.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            swap.centerYAnchor.constraint(equalTo: titleRow.centerYAnchor),
            swap.heightAnchor.constraint(equalTo: titleRow.heightAnchor),
            swap.widthAnchor.constraint(equalToConstant: 110),
        ])
    }

    private func makeTitleLabel(slot: CameraSlot) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "Camera \(slot.label)")
        label.textColor = .white
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        titleLabels[slot] = label
        return container
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

        // Camera LED toggle. Deliberately an AppKit view layered over the VideoView, never
        // composited into the CVPixelBuffer — Syphon publishes that buffer straight from the
        // decoder, so overlays are excluded from the Syphon output by construction.
        // Top-right of each pane.
        let light = NSButton(title: "💡", target: self, action: #selector(toggleLight(_:)))
        light.tag = slot.rawValue
        light.isBordered = false
        light.font = NSFont.systemFont(ofSize: 20)
        light.wantsLayer = true
        light.layer?.cornerRadius = 6
        light.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(light)
        NSLayoutConstraint.activate([
            light.topAnchor.constraint(equalTo: pane.topAnchor, constant: 8),
            light.widthAnchor.constraint(equalToConstant: 36),
            light.heightAnchor.constraint(equalToConstant: 30),
            light.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -8),
        ])

        videoViews[slot]     = videoView
        statusLabels[slot]   = label
        statusOverlays[slot] = pill
        lightButtons[slot]   = light
        torchOn[slot]        = false
        applyLightAppearance(slot)
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
            // When a slot loses its feed, wipe the frozen last frame behind the overlay, and
            // drop the stale battery reading — it's a different phone by the time one reconnects.
            if msg.contains("Searching") || msg.contains("lost") {
                self.videoViews[slot]?.clear()
                self.titleLabels[slot]?.stringValue = "Camera \(slot.label)"
                self.torchOn[slot] = false
                self.applyLightAppearance(slot)
            }
        }
        browser.onBattery = { [weak self] slot, level, charging in
            guard let self else { return }
            let bolt = charging ? "⚡" : ""
            self.titleLabels[slot]?.stringValue = "Camera \(slot.label) — \(bolt)\(level)%"
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
