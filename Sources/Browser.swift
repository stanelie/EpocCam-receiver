import Foundation
import Network
import CoreVideo

// Discovers _epoccam._tcp streamers and maintains up to two concurrent connections,
// each published to its own Syphon output ("EpocCam A" / "EpocCam B").
//
// Slot assignment is done entirely on the viewer side — the phones need no special
// firmware. Each connection is identified once it goes live by the phone's MAC
// address (read from the resolved peer: EUI-64 link-local, or an ARP lookup of the
// IPv4), falling back to the IP string when a MAC can't be determined. A persisted
// map (deviceKey -> slot) keeps a given phone on the same slot across reconnects and
// relaunches; the operator can flip the two with swapSlots() ("Swap A ↔ B").
final class EpocCamBrowser {
    // All callbacks are tagged with the slot they belong to.
    var onFrame:   ((CameraSlot, CVPixelBuffer) -> Void)?
    var onFormats: ((CameraSlot, [VideoFormat]) -> Void)?
    // Fired on the main thread with a human-readable status string.
    var onStatus:  ((CameraSlot, String) -> Void)?

    // One managed connection = one phone. Its slot is decided once it's live.
    private final class ManagedConn {
        let serviceKey: NWEndpoint        // the discovered mDNS service this represents
        let endpoint: NWEndpoint          // endpoint we actually dialled (ip or hostname)
        let advertisedId: String?         // stable device id from TXT, if the streamer sent one
        var conn: EpocCamConnection?
        var live = false
        var everLive = false              // did this connection ever reach .ready?
        var dropped = false               // teardown started (makes handleDisconnect idempotent)
        var lastActivity = CFAbsoluteTimeGetCurrent()  // last frame / connect — for the stall watchdog
        var deviceKey: String?            // slot key, known once live
        var slot: CameraSlot?             // published slot, known once assigned
        init(serviceKey: NWEndpoint, endpoint: NWEndpoint, advertisedId: String?) {
            self.serviceKey = serviceKey
            self.endpoint = endpoint
            self.advertisedId = advertisedId
        }
    }

    // What a discovered service resolves to. We prefer `primary` (the streamer's advertised
    // IP — unambiguous even when two Android phones share the "Android.local" hostname), but
    // fall back to `resolve` (the mDNS service endpoint / hostname) if the IP won't connect —
    // e.g. it went stale after a Wi-Fi roam. `resolve` is what an IP-less streamer (the
    // original iPhone) uses from the start.
    private struct Service {
        let primary: NWEndpoint
        let resolve: NWEndpoint
        let id: String?
    }

    private var conns: [ManagedConn] = []
    private var discovered: [NWEndpoint: Service] = [:]   // service endpoint -> Service
    // service endpoint -> consecutive failures dialling `primary` without ever going live.
    // Once >0 we try `resolve` (hostname) instead, so a stale advertised IP self-heals.
    private var primaryFailures: [NWEndpoint: Int] = [:]
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "epoccam.browser", qos: .userInitiated)
    private var pendingWork: [DispatchWorkItem] = []

    private static let kSlotMapKey = "EpocCamSlotMap"       // deviceKey -> slot rawValue

    func start() {
        startBrowser()
        scheduleWatchdog()
    }

    // A live TCP connection can go silent without a clean close (Wi-Fi roam / phone sleep /
    // network drop), which would otherwise pin a pool slot forever. Periodically drop any
    // connection that stopped delivering frames so it reconnects (to the phone's fresh
    // advertised address).
    private static let kStallTimeout = 6.0
    private func scheduleWatchdog() {
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            for mc in self.conns where mc.everLive && !mc.dropped {
                if now - mc.lastActivity > Self.kStallTimeout {
                    NSLog("EpocCam: no frames for %.0fs on %@ – dropping stalled connection",
                          now - mc.lastActivity, mc.deviceKey ?? "?")
                    mc.conn?.cancel()
                    self.handleDisconnect(mc)
                }
            }
            self.scheduleWatchdog()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingWork.forEach { $0.cancel() }
            self.pendingWork.removeAll()
            self.conns.forEach { $0.conn?.cancel() }
            self.conns.removeAll()
            self.browser?.cancel()
            self.browser = nil
        }
    }

    func selectFormat(slot: CameraSlot, index: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(index, forKey: slot.lastFormatKey)
            self.conns.first { $0.slot == slot && $0.live }?.conn?.selectFormat(index: index)
        }
    }

    // Operator control: swap the two live feeds' slots (or move the single one to the
    // other slot). Persists so the choice sticks across restarts.
    func swapSlots() {
        queue.async { [weak self] in
            guard let self else { return }
            let live = self.conns.filter { $0.live && $0.slot != nil }
            switch live.count {
            case 2:
                let a = live[0], b = live[1]
                let sa = a.slot!, sb = b.slot!
                a.slot = sb; b.slot = sa
                self.persistSlot(a); self.persistSlot(b)
                NSLog("EpocCam: swapped — %@↔%@", sa.label, sb.label)
                // Both panes stay filled; a fresh frame will refresh each.
            case 1:
                let a = live[0]
                let old = a.slot!
                let other: CameraSlot = old == .a ? .b : .a
                a.slot = other
                self.persistSlot(a)
                NSLog("EpocCam: moved single feed %@ -> %@", old.label, other.label)
                self.postStatus(old, "Searching for camera \(old.label)…")
            default:
                NSLog("EpocCam: swap requested but no live feeds")
            }
        }
    }

    // MARK: - Discovery

    private func startBrowser() {
        // bonjourWithTXTRecord so we can read the streamer's advertised "ip".
        let desc   = NWBrowser.Descriptor.bonjourWithTXTRecord(type: kService, domain: "local.")
        let params = NWParameters.tcp
        let b      = NWBrowser(for: desc, using: params)

        b.browseResultsChangedHandler = { [weak self] _, changes in
            guard let self else { return }
            for change in changes {
                switch change {
                case .added(let result):
                    self.discovered[result.endpoint] = self.service(for: result)
                    self.connectMoreIfPossible()
                case .changed(old: _, new: let result, flags: _):
                    self.discovered[result.endpoint] = self.service(for: result)
                    self.connectMoreIfPossible()
                case .removed(let result):
                    self.discovered.removeValue(forKey: result.endpoint)
                default:
                    break
                }
            }
        }

        b.stateUpdateHandler = { [weak self] state in
            NSLog("EpocCam: browser state -> %@", "\(state)")
            guard let self else { return }
            switch state {
            case .failed(let err):
                NSLog("EpocCam: browser failed: %@ – restarting in 5s", err.localizedDescription)
                self.browser = nil
                self.queue.asyncAfter(deadline: .now() + 5.0) { [weak self] in self?.startBrowser() }
            case .waiting(let err):
                NSLog("EpocCam: browser waiting: %@", err.localizedDescription)
            default:
                break
            }
        }

        b.start(queue: queue)
        browser = b
    }

    // Dial any discovered services we're not already talking to, up to two connections.
    // One connection per service; if its advertised IP has been failing, dial the mDNS
    // hostname instead (self-heals a stale IP).
    private func connectMoreIfPossible() {
        for (svcKey, svc) in discovered {
            guard conns.count < 2 else { break }
            guard !conns.contains(where: { $0.serviceKey == svcKey }) else { continue }
            let useFallback = (primaryFailures[svcKey] ?? 0) > 0 && svc.resolve != svc.primary
            let dial = useFallback ? svc.resolve : svc.primary
            if useFallback { NSLog("EpocCam: advertised IP failing – dialling hostname %@", "\(svc.resolve)") }
            connect(service: svcKey, to: dial, advertisedId: svc.id)
        }
    }

    // Resolve a browse result: prefer the streamer's advertised IP (unambiguous) and
    // pick up its stable "id"; keep the mDNS service endpoint as the hostname fallback.
    // A streamer that advertises no IP (the original iPhone) uses the hostname from the start.
    private func service(for result: NWBrowser.Result) -> Service {
        let resolve = result.endpoint
        var primary = result.endpoint
        var id: String? = nil
        if case let .bonjour(txt) = result.metadata {
            if let advertised = txt["id"], !advertised.isEmpty { id = advertised }
            if let ip = txt["ip"], !ip.isEmpty, let port = NWEndpoint.Port(rawValue: kPort) {
                primary = .hostPort(host: NWEndpoint.Host(ip), port: port)
            }
        }
        return Service(primary: primary, resolve: resolve, id: id)
    }

    private func connect(service svcKey: NWEndpoint, to endpoint: NWEndpoint, advertisedId: String? = nil) {
        let mc = ManagedConn(serviceKey: svcKey, endpoint: endpoint, advertisedId: advertisedId)
        conns.append(mc)

        let c = EpocCamConnection(endpoint: endpoint, queue: queue, initialFormatIndex: 0)
        c.onFrame = { [weak self, weak mc] pb in
            guard let self, let mc, let slot = mc.slot else { return }
            mc.lastActivity = CFAbsoluteTimeGetCurrent()
            self.onFrame?(slot, pb)
        }
        c.onFormats = { [weak self, weak mc] formats in
            guard let self, let mc, let slot = mc.slot else { return }
            self.onFormats?(slot, formats)
        }
        c.onConnected = { [weak self, weak mc] resolved in
            guard let self, let mc else { return }
            self.handleLive(mc, resolved: resolved)
        }
        c.onDisconnect = { [weak self, weak mc] in
            guard let self, let mc else { return }
            self.handleDisconnect(mc)
        }
        c.start()
        mc.conn = c
        NSLog("EpocCam: connecting to %@", endpoint.debugDescription)
    }

    // MARK: - Identity & assignment

    private func handleLive(_ mc: ManagedConn, resolved: NWEndpoint?) {
        mc.live = true
        mc.everLive = true
        mc.lastActivity = CFAbsoluteTimeGetCurrent()   // start the stall window from connect
        primaryFailures[mc.serviceKey] = 0   // this dial worked; reset the fallback counter
        // Slot-key priority: the streamer's stable advertised id (survives IP/MAC changes)
        // → the peer MAC → the IP. The original iPhone has no id, so it uses MAC/IP.
        let key = mc.advertisedId.map { "id:\($0)" }
            ?? deviceKey(from: resolved)
            ?? "ep:\(mc.endpoint.debugDescription)"

        // Same phone reached twice (e.g. two mDNS names / IPv4+IPv6) — keep the first.
        if let dup = conns.first(where: { $0 !== mc && $0.live && $0.deviceKey == key }) {
            NSLog("EpocCam: dropping duplicate connection to %@ (already on slot %@)",
                  key, dup.slot?.label ?? "?")
            dropConnection(mc, notifySlot: false)
            return
        }
        mc.deviceKey = key

        guard let slot = assignSlot(for: key) else {
            NSLog("EpocCam: no free slot for %@ – dropping", key)
            dropConnection(mc, notifySlot: false)
            return
        }
        mc.slot = slot
        remember(key: key, slot: slot)

        NSLog("EpocCam[%@]: live device %@", slot.label, key)
        postStatus(slot, "Camera \(slot.label) connected – receiving video…")

        // Apply this slot's remembered resolution to the freshly bound phone.
        let fmt = UserDefaults.standard.integer(forKey: slot.lastFormatKey)
        if fmt > 0 { mc.conn?.selectFormat(index: fmt) }
    }

    // Pick a slot for a device: its remembered slot if free, else the first free slot.
    private func assignSlot(for key: String) -> CameraSlot? {
        func isFree(_ slot: CameraSlot) -> Bool {
            !conns.contains { $0.slot == slot && $0.deviceKey != key }
        }
        if let remembered = rememberedSlot(for: key), isFree(remembered) { return remembered }
        return CameraSlot.allCases.first { isFree($0) }
    }

    private func handleDisconnect(_ mc: ManagedConn) {
        guard !mc.dropped else { return }   // idempotent: watchdog + natural close can both fire
        mc.dropped = true
        // Never reached .ready — the dialled address is likely bad (e.g. a stale advertised
        // IP after a roam). Count it so the next attempt falls back to hostname resolution.
        if !mc.everLive {
            primaryFailures[mc.serviceKey, default: 0] += 1
        }
        let freed = mc.slot
        dropConnection(mc, notifySlot: true)
        if let slot = freed {
            NSLog("EpocCam[%@] disconnected – will reconnect", slot.label)
        }
        // Reconnect the same phone (still discovered) or pick up a waiting one.
        scheduleReconnect(delay: 1.0)
    }

    private func dropConnection(_ mc: ManagedConn, notifySlot: Bool) {
        mc.conn?.cancel()
        mc.conn = nil
        mc.live = false
        conns.removeAll { $0 === mc }
        if notifySlot, let slot = mc.slot {
            postStatus(slot, "Searching for camera \(slot.label)…")
        }
    }

    // MARK: - Reconnect / fast start

    // Reconnect after a drop: mDNS is the single source of truth, so just re-dial any
    // still-discovered endpoints. (No parallel "last host" probe — a second connection
    // to the same phone would fight the phone's single-connection server.)
    private func scheduleReconnect(delay: Double) {
        let w = DispatchWorkItem { [weak self] in
            self?.connectMoreIfPossible()
        }
        pendingWork.append(w)
        queue.asyncAfter(deadline: .now() + delay, execute: w)
    }

    // MARK: - Persistence

    private func rememberedSlot(for key: String) -> CameraSlot? {
        let map = UserDefaults.standard.dictionary(forKey: Self.kSlotMapKey) as? [String: Int]
        guard let raw = map?[key] else { return nil }
        return CameraSlot(rawValue: raw)
    }

    private func remember(key: String, slot: CameraSlot) {
        var map = (UserDefaults.standard.dictionary(forKey: Self.kSlotMapKey) as? [String: Int]) ?? [:]
        if map[key] != slot.rawValue {
            map[key] = slot.rawValue
            UserDefaults.standard.set(map, forKey: Self.kSlotMapKey)
        }
    }

    private func persistSlot(_ mc: ManagedConn) {
        if let key = mc.deviceKey, let slot = mc.slot { remember(key: key, slot: slot) }
    }

    // MARK: - MAC / IP identity

    // Best-effort stable identity for the peer we connected to.
    private func deviceKey(from endpoint: NWEndpoint?) -> String? {
        guard case .hostPort(let host, _)? = endpoint else { return nil }
        switch host {
        case .ipv6(let addr):
            if let mac = macFromEUI64(addr) { return "mac:\(mac)" }   // MAC embedded in the address
            if let mac = macFromNeighbor("\(addr)") { return "mac:\(mac)" } // else the NDP table (e.g. iPhone privacy addr)
            return "ip:\(addr)"
        case .ipv4(let addr):
            if let mac = macFromARP("\(addr)") { return "mac:\(mac)" }
            return "ip:\(addr)"
        case .name(let n, _):
            return "host:\(n.lowercased())"
        @unknown default:
            return nil
        }
    }

    // Extract the MAC embedded in a modified-EUI-64 IPv6 address (…ff:fe… in the middle).
    private func macFromEUI64(_ addr: IPv6Address) -> String? {
        let b = [UInt8](addr.rawValue)
        guard b.count == 16, b[11] == 0xff, b[12] == 0xfe else { return nil }
        let mac = [b[8] ^ 0x02, b[9], b[10], b[13], b[14], b[15]]
        return mac.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    // Look up a MAC for an IPv4 in the host's ARP table.
    private func macFromARP(_ ip: String) -> String? {
        guard let out = runTool("/usr/sbin/arp", ["-n", ip]) else { return nil }
        // e.g. "? (10.8.0.234) at 30:7:4d:d8:10:d7 on en1 ifscope [ethernet]"
        guard let atRange = out.range(of: " at ") else { return nil }
        let after = out[atRange.upperBound...]
        let token = after.split(whereSeparator: { $0 == " " }).first.map(String.init) ?? ""
        return normalizeMAC(token)
    }

    // Look up a MAC for an IPv6 in the host's neighbor (NDP) table. Recovers a stable
    // key for peers whose address doesn't embed the MAC — e.g. an iPhone's privacy
    // link-local address, which otherwise rotates.
    private func macFromNeighbor(_ ip: String) -> String? {
        guard let out = runTool("/usr/sbin/ndp", ["-an"]) else { return nil }
        // e.g. "fe80::10bd:8c75:ec9:d4a9%en0  8c:f5:a3:8f:c5:03  en0 ..."
        let target = ip.split(separator: "%").first.map(String.init) ?? ip
        for line in out.split(separator: "\n") {
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard cols.count >= 2 else { continue }
            let addr = cols[0].split(separator: "%").first.map(String.init) ?? cols[0]
            if addr.caseInsensitiveCompare(target) == .orderedSame {
                return normalizeMAC(cols[1])
            }
        }
        return nil
    }

    // Zero-pad each octet so ARP ("30:7:4d:…") and EUI-64 ("30:07:4d:…") keys match.
    private func normalizeMAC(_ raw: String) -> String? {
        let parts = raw.split(separator: ":")
        guard parts.count == 6 else { return nil }
        var octets: [String] = []
        for p in parts {
            guard let v = UInt8(p, radix: 16) else { return nil }
            octets.append(String(format: "%02x", v))
        }
        return octets.joined(separator: ":")
    }

    private func runTool(_ path: String, _ args: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    private func postStatus(_ slot: CameraSlot, _ msg: String) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(slot, msg) }
    }
}
