import Foundation
import Network

// Manages one TCP connection to an EpocCam streamer.
// Caller provides an endpoint; call start() to connect.
// onDisconnect fires on any error or clean close.
final class EpocCamConnection {
    var onFrame:      ((CVPixelBuffer) -> Void)?
    var onDisconnect: (() -> Void)?
    var onConnected:  ((NWEndpoint?) -> Void)?
    // Called once the capability packet is parsed; passes the available formats.
    var onFormats:    (([VideoFormat]) -> Void)?
    // Called whenever a battery packet arrives: (level 0-100, charging).
    var onBattery:    ((Int, Bool) -> Void)?
    // Called whenever the phone reports what its focus is doing.
    var onFocusState: ((FocusState) -> Void)?
    // The compressed H.264 exactly as the phone sent it, for the NDI passthrough path:
    // (annexB frame, isKeyframe, parameterSets for keyframes). Fires alongside decoding,
    // never instead of it — Syphon and the preview still need decoded frames.
    var onCompressedVideo: ((Data, Bool, Data?) -> Void)?

    // Last SPS+PPS seen, so a keyframe can carry them even when they arrived in a separate
    // config packet rather than bundled with the IDR.
    private var parameterSets: Data?

    private let conn:    NWConnection
    private let queue:   DispatchQueue
    private var buffer   = Data()
    private let decoder  = VideoDecoder()
    private var live     = false
    private var activeFormatIndex: Int = 0

    init(endpoint: NWEndpoint, queue: DispatchQueue, initialFormatIndex: Int = 0) {
        self.activeFormatIndex = initialFormatIndex
        self.queue = queue
        conn = NWConnection(to: endpoint, using: .tcp)
        decoder.onFrame = { [weak self] pb in self?.onFrame?(pb) }
    }

    func start() {
        // Cancel unresolved connections so the reconnect loop can try again — NWConnection
        // can otherwise sit in .preparing indefinitely on a stale mDNS cache entry. Kept
        // short because a reachable phone now answers in milliseconds (it holds a
        // MulticastLock, so it replies to ARP directly); the only thing this budget buys is
        // how long an absent phone occupies a connection slot before we move on.
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, !self.live else { return }
            NSLog("EpocCam: connection timeout – cancelling")
            self.conn.cancel()
            self.onDisconnect?()
        }

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            NSLog("EpocCam: conn state -> %@", "\(state)")
            switch state {
            case .ready:
                self.live = true
                // Report the resolved remote endpoint for last-known-host caching
                let remote = self.conn.currentPath?.remoteEndpoint
                NSLog("EpocCam: conn ready, remote=%@", remote.map { "\($0)" } ?? "nil")
                self.onConnected?(remote)
                // Send format-select immediately so senders that require a viewer
                // greeting before streaming (e.g. original iOS EpocCam) start up.
                // Android senders ignore this early one and respond to the one sent
                // after the capability packet instead.
                self.sendFormatSelect(index: self.activeFormatIndex)
                self.receive()
            case .waiting(let err):
                // Logged only — the 4s startup timeout in start() handles cancellation
                // so we don't fire onDisconnect twice (once here, once from the timeout).
                NSLog("EpocCam: conn waiting: %@", err.localizedDescription)
            case .failed(let err):
                NSLog("EpocCam: conn failed: %@", err.localizedDescription)
                guard self.live else { return }
                self.live = false
                self.onDisconnect?()
            case .cancelled:
                guard self.live else { return }
                self.live = false
                self.onDisconnect?()
            default: break
            }
        }
        conn.start(queue: queue)
    }

    func cancel() {
        live = false
        conn.cancel()
    }

    // MARK: - Receive loop

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isDone, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.process(data)
            }
            if isDone || error != nil {
                guard self.live else { return }
                self.live = false
                self.onDisconnect?()
                return
            }
            self.receive()
        }
    }

    private func process(_ data: Data) {
        buffer.append(data)
        while buffer.count >= PktHeader.size {
            guard let hdr = PktHeader(bytes: buffer) else {
                // Bad magic – connection is corrupt, drop it
                live = false
                conn.cancel()
                onDisconnect?()
                return
            }
            // Use totalSize (reliable) rather than payloadSize (sentinel 0x01000000 in capability pkts)
            guard hdr.totalSize >= 12 else {
                live = false; conn.cancel(); onDisconnect?(); return
            }
            let payloadLen = Int(hdr.totalSize) - 12
            let total = PktHeader.size + payloadLen
            guard buffer.count >= total else { break }
            let payloadStart = buffer.startIndex + PktHeader.size
            let payloadEnd   = buffer.startIndex + total
            let payload = payloadLen > 0 ? buffer.subdata(in: payloadStart..<payloadEnd) : Data()
            buffer.removeFirst(total)
            // Re-normalize backing so startIndex=0 for next iteration (removeFirst may leave a slice)
            if buffer.startIndex != 0 { buffer = Data(buffer) }
            NSLog("EpocCam: pkt type=0x%08X totalSize=%d payloadLen=%d flags=0x%08X",
                  hdr.type, hdr.totalSize, payloadLen, hdr.flags)
            handle(header: hdr, payload: payload)
        }
    }

    // MARK: - Packet handling

    private func handle(header: PktHeader, payload: Data) {
        switch header.type {
        case PktType.capability.rawValue:
            NSLog("EpocCam: capability packet received (%d bytes payload), sending format-select", payload.count)
            let formats = parseCapabilityFormats(payload)
            NSLog("EpocCam: advertised formats: %@", formats.map { $0.label }.joined(separator: ", "))
            if !formats.isEmpty { onFormats?(formats) }
            sendFormatSelect(index: activeFormatIndex)

        case PktType.video.rawValue:
            decoder.handle(payload: payload, flags: header.flags)
            forwardCompressed(payload: payload, flags: header.flags)

        case PktType.focusState.rawValue:
            guard payload.count >= 1, let st = FocusState(rawValue: Int(payload[0])) else { break }
            NSLog("EpocCam: focus state: %d", st.rawValue)
            onFocusState?(st)

        case PktType.battery.rawValue:
            guard payload.count >= 2 else { break }
            let level = Int(payload[0])
            let charging = payload[1] != 0
            NSLog("EpocCam: battery packet: %d%% charging=%@", level, charging ? "true" : "false")
            onBattery?(level, charging)

        default:
            NSLog("EpocCam: unknown packet type 0x%08X (%d bytes)", header.type, payload.count)
        }
    }

    private func forwardCompressed(payload: Data, flags: UInt32) {
        guard onCompressedVideo != nil else { return }
        // The decoder-reset sentinel isn't video; don't forward it.
        if payload == kResetPayload { return }
        // A config-only packet carries SPS/PPS and no picture — remember, emit nothing.
        if flags & kFlagConfig != 0 {
            parameterSets = extractParameterSets(payload) ?? parameterSets
            return
        }
        let isKey = annexBContainsIDR(payload)
        if isKey, let sets = extractParameterSets(payload) { parameterSets = sets }
        onCompressedVideo?(payload, isKey, isKey ? parameterSets : nil)
    }

    func selectFormat(index: Int) {
        guard live else { return }
        activeFormatIndex = index
        sendFormatSelect(index: index)
    }

    // Toggle the phone's camera LED. Fire-and-forget: the phone doesn't acknowledge, so
    // the viewer's button reflects what was *requested*, not confirmed hardware state.
    func setTorch(on: Bool) {
        guard live else { return }
        conn.send(content: Data.torchPacket(on: on), completion: .contentProcessed { err in
            if let err { NSLog("EpocCam: torch send error: %@", err.localizedDescription) }
            else { NSLog("EpocCam: torch %@ sent", on ? "ON" : "OFF") }
        })
    }

    func sendFocusCommand(_ cmd: Data.FocusCommand) {
        guard live else { return }
        conn.send(content: Data.focusCommandPacket(cmd), completion: .contentProcessed { err in
            if let err { NSLog("EpocCam: focus cmd send error: %@", err.localizedDescription) }
        })
    }

    private func sendFormatSelect(index: Int) {
        let pkt = Data.formatSelectPacket(index: UInt16(index))
        conn.send(content: pkt, completion: .contentProcessed { err in
            if let err { NSLog("EpocCam: format-select send error: %@", err.localizedDescription) }
            else { NSLog("EpocCam: format-select sent (index %d)", index) }
        })
    }
}
