import Foundation
import Network
import CoreVideo

// Continuously browses for _epoccam._tcp services and maintains one connection.
// Falls back to the last known host (stored in UserDefaults) if mDNS is slow.
final class EpocCamBrowser {
    var onFrame:   ((CVPixelBuffer) -> Void)?
    var onFormats: (([VideoFormat]) -> Void)?

    private var browser:    NWBrowser?
    private var connection: EpocCamConnection?
    private var endpoints:  [NWEndpoint] = []
    private let queue = DispatchQueue(label: "epoccam.browser", qos: .userInitiated)

    // Pending fallback work items; cancelled once a connection becomes ready.
    private var pendingWork: [DispatchWorkItem] = []

    // Last known host stored across launches
    private static let kLastHostKey = "EpocCamLastHost"
    private static let kLastPortKey = "EpocCamLastPort"

    func start() {
        startBrowser()
        scheduleStartupFallbacks()
    }

    func selectFormat(index: Int) {
        queue.async { [weak self] in
            self?.connection?.selectFormat(index: index)
        }
    }

    func stop() {
        cancelPendingWork()
        browser?.cancel()
        connection?.cancel()
        browser    = nil
        connection = nil
    }

    // Called when a connection succeeds — saves the resolved host for future fallback
    func recordSuccessfulHost(_ endpoint: NWEndpoint) {
        if case .hostPort(let host, let port) = endpoint {
            let hostStr = "\(host)"
            NSLog("EpocCam: saving last host: %@:%d", hostStr, port.rawValue)
            UserDefaults.standard.set(hostStr, forKey: EpocCamBrowser.kLastHostKey)
            UserDefaults.standard.set(Int(port.rawValue), forKey: EpocCamBrowser.kLastPortKey)
        }
    }

    // MARK: - Private

    private func cancelPendingWork() {
        pendingWork.forEach { $0.cancel() }
        pendingWork.removeAll()
    }

    private func startBrowser() {
        let desc   = NWBrowser.Descriptor.bonjour(type: kService, domain: "local.")
        let params = NWParameters.tcp
        let b      = NWBrowser(for: desc, using: params)

        b.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self else { return }
            for change in changes {
                switch change {
                case .added(let result):
                    NSLog("EpocCam: mDNS found: %@", result.endpoint.debugDescription)
                    if !self.endpoints.contains(result.endpoint) {
                        self.endpoints.append(result.endpoint)
                    }
                    if self.connection == nil {
                        self.connect(to: result.endpoint)
                    }
                case .removed(let result):
                    NSLog("EpocCam: mDNS lost: %@", result.endpoint.debugDescription)
                    self.endpoints.removeAll { $0 == result.endpoint }
                default:
                    break
                }
            }
        }

        b.stateUpdateHandler = { state in
            NSLog("EpocCam: browser state -> %@", "\(state)")
        }

        b.start(queue: queue)
        browser = b
    }

    // On first launch: try last-known-host after 3s if mDNS hasn't found anything.
    // Work items are cancelled as soon as a connection goes ready.
    private func scheduleStartupFallbacks() {
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.connection == nil else { return }
            if let host = UserDefaults.standard.string(forKey: EpocCamBrowser.kLastHostKey) {
                let rawPort = UserDefaults.standard.integer(forKey: EpocCamBrowser.kLastPortKey)
                let port = rawPort > 0 ? UInt16(rawPort) : kPort
                NSLog("EpocCam: mDNS slow, trying last known host: %@:%d", host, port)
                self.connectDirect(host: host, port: port)
            }
        }
        pendingWork.append(w)
        queue.asyncAfter(deadline: .now() + 3.0, execute: w)
    }

    private func connectDirect(host: String, port: UInt16) {
        guard connection == nil else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        connect(to: endpoint)
    }

    private func connect(to endpoint: NWEndpoint) {
        let c = EpocCamConnection(endpoint: endpoint, queue: queue)
        c.onFrame   = { [weak self] pb in self?.onFrame?(pb) }
        c.onFormats = { [weak self] formats in self?.onFormats?(formats) }
        c.onConnected = { [weak self] resolvedEndpoint in
            guard let self else { return }
            // Cancel any pending startup fallback timers — we have a live connection.
            self.cancelPendingWork()
            if let ep = resolvedEndpoint { self.recordSuccessfulHost(ep) }
        }
        c.onDisconnect = { [weak self] in
            guard let self else { return }
            self.connection = nil
            NSLog("EpocCam disconnected – reconnecting in 1s")
            let w = DispatchWorkItem { [weak self] in
                guard let self, self.connection == nil else { return }
                // Prefer a live mDNS endpoint, otherwise use last-known-host.
                if let ep = self.endpoints.first {
                    NSLog("EpocCam: reconnecting via mDNS endpoint")
                    self.connect(to: ep)
                } else if let host = UserDefaults.standard.string(forKey: EpocCamBrowser.kLastHostKey) {
                    let rawPort = UserDefaults.standard.integer(forKey: EpocCamBrowser.kLastPortKey)
                    let port = rawPort > 0 ? UInt16(rawPort) : kPort
                    NSLog("EpocCam: reconnecting to last known host: %@:%d", host, port)
                    self.connectDirect(host: host, port: port)
                } else {
                    NSLog("EpocCam: no known host, waiting for mDNS")
                }
            }
            self.pendingWork.append(w)
            self.queue.asyncAfter(deadline: .now() + 1.0, execute: w)
        }
        c.start()
        connection = c
        NSLog("EpocCam connecting to %@", endpoint.debugDescription)
    }
}
