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
        // Cancel unresolved connections after 8s so the reconnect loop can try again.
        // NWConnection can stay in .preparing indefinitely on a stale mDNS cache entry.
        queue.asyncAfter(deadline: .now() + 4.0) { [weak self] in
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

        default:
            NSLog("EpocCam: unknown packet type 0x%08X (%d bytes)", header.type, payload.count)
        }
    }

    func selectFormat(index: Int) {
        guard live else { return }
        activeFormatIndex = index
        sendFormatSelect(index: index)
    }

    private func sendFormatSelect(index: Int) {
        let pkt = Data.formatSelectPacket(index: UInt16(index))
        conn.send(content: pkt, completion: .contentProcessed { err in
            if let err { NSLog("EpocCam: format-select send error: %@", err.localizedDescription) }
            else { NSLog("EpocCam: format-select sent (index %d)", index) }
        })
    }
}
