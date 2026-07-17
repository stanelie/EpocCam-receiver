import Foundation

let kMagic: UInt32    = 0xDEADC0DE
let kPort: UInt16     = 5054
let kService          = "_epoccam._tcp"

// A camera slot. Each slot drives its own Syphon output so Millumin sees two
// distinct sources. A streamer is bound to a slot by its advertised role (mDNS),
// and role-less/legacy devices (e.g. the original iPhone) are auto-assigned and
// then remembered so they always return to the same slot.
enum CameraSlot: Int, CaseIterable {
    case a = 0
    case b = 1

    var label: String { self == .a ? "A" : "B" }
    var syphonName: String { "EpocCam \(label)" }

    // Per-slot UserDefaults keys (last-known host/port for fast reconnect, last format).
    var lastHostKey:   String { "EpocCamLastHost.\(label)" }
    var lastPortKey:   String { "EpocCamLastPort.\(label)" }
    var lastFormatKey: String { "EpocCamLastFormat.\(label)" }

    static func from(role: String?) -> CameraSlot? {
        switch role?.lowercased() {
        case "a": return .a
        case "b": return .b
        default:  return nil
        }
    }
}

enum PktType: UInt32 {
    case video      = 0x00020002
    case fmtSelect  = 0x00020003
    case audio      = 0x00020004
    case capability = 0x00020005
}

struct PktHeader {
    static let size = 28

    let magic:       UInt32
    let reserved:    UInt32
    let type:        UInt32
    let totalSize:   UInt32
    let flags:       UInt32   // 0x08 = config (SPS/PPS), 0x10 = front cam
    let timestamp:   UInt32
    let payloadSize: UInt32

    init?(bytes: Data) {
        guard bytes.count >= PktHeader.size else { return nil }
        magic       = bytes.leU32(0)
        guard magic == kMagic else { return nil }
        reserved    = bytes.leU32(4)
        type        = bytes.leU32(8)
        totalSize   = bytes.leU32(12)
        flags       = bytes.leU32(16)
        timestamp   = bytes.leU32(20)
        payloadSize = bytes.leU32(24)
    }
}

// A single resolution/codec format advertised in the capability packet.
struct VideoFormat {
    let index:  Int
    let width:  Int
    let height: Int
    let fps:    Float

    var label: String {
        let fpsStr = fps > 0 ? " @ \(Int(fps))fps" : ""
        return "\(width)×\(height)\(fpsStr)"
    }
}

// Parse the formats from a capability packet payload.
// Layout: [0-3] numFormats LE, then numFormats × 8 bytes each:
//   [0-3] VideoSize: bits 0-11 = width, bits 12-23 = height, bits 24-31 = codec
//   [4-7] frame rate as little-endian float32
func parseCapabilityFormats(_ payload: Data) -> [VideoFormat] {
    let bytes = payload.startIndex == 0 ? payload : Data(payload)
    guard bytes.count >= 4 else { return [] }
    let count = Int(bytes.leU32(0))
    guard count > 0, count <= 16 else { return [] }
    var formats: [VideoFormat] = []
    for i in 0..<count {
        let offset = 4 + i * 8
        guard offset + 8 <= bytes.count else { break }
        let vs   = bytes.leU32(offset)
        let w    = Int(vs & 0xFFF)
        let h    = Int((vs >> 12) & 0xFFF)
        let fpsRaw = bytes.leU32(offset + 4)
        let fps  = Float(bitPattern: fpsRaw)
        guard w > 0, h > 0 else { continue }
        formats.append(VideoFormat(index: i, width: w, height: h, fps: fps))
    }
    return formats
}

let kFlagConfig: UInt32 = 0x08
let kFlagFront:  UInt32 = 0x10
let kResetPayload        = Data([0x00, 0x00, 0x00, 0x05])

extension Data {
    // Use startIndex-relative access so this works on both full Data and slices after removeFirst.
    func leU32(_ offset: Int) -> UInt32 {
        let b = startIndex + offset
        return UInt32(self[b])
            | UInt32(self[b+1]) << 8
            | UInt32(self[b+2]) << 16
            | UInt32(self[b+3]) << 24
    }

    mutating func putLeU32(_ v: UInt32, at offset: Int) {
        let b = startIndex + offset
        self[b]   = UInt8(v & 0xFF)
        self[b+1] = UInt8((v >> 8) & 0xFF)
        self[b+2] = UInt8((v >> 16) & 0xFF)
        self[b+3] = UInt8((v >> 24) & 0xFF)
    }

    // Build a format-select packet (viewer → streamer)
    static func formatSelectPacket(index: UInt16) -> Data {
        var p = Data(count: 256)
        p.putLeU32(kMagic,      at: 0)
        p.putLeU32(0,           at: 4)
        p.putLeU32(PktType.fmtSelect.rawValue, at: 8)
        p.putLeU32(UInt32(244), at: 12)   // remaining bytes
        p[16] = UInt8(index & 0xFF)
        p[17] = UInt8((index >> 8) & 0xFF)
        return p
    }
}

// Split an Annex-B byte stream into raw NAL units (start codes stripped).
// Handles both 3-byte (00 00 01) and 4-byte (00 00 00 01) start codes.
func splitAnnexB(_ data: Data) -> [Data] {
    // Normalize to zero-startIndex so index arithmetic below is simple
    let bytes = data.startIndex == 0 ? data : Data(data)
    var result: [Data] = []
    var i = 0
    var nalStart = -1

    while i < bytes.count - 2 {
        // Detect 4-byte start code: 00 00 00 01
        if i + 3 < bytes.count,
           bytes[i] == 0, bytes[i+1] == 0, bytes[i+2] == 0, bytes[i+3] == 1
        {
            if nalStart >= 0 {
                let nal = bytes.subdata(in: nalStart..<i)
                if !nal.isEmpty { result.append(nal) }
            }
            nalStart = i + 4
            i += 4
            continue
        }
        // Detect 3-byte start code: 00 00 01
        if bytes[i] == 0, bytes[i+1] == 0, bytes[i+2] == 1 {
            if nalStart >= 0 {
                let nal = bytes.subdata(in: nalStart..<i)
                if !nal.isEmpty { result.append(nal) }
            }
            nalStart = i + 3
            i += 3
            continue
        }
        i += 1
    }
    if nalStart >= 0, nalStart < bytes.count {
        let nal = bytes.subdata(in: nalStart..<bytes.count)
        if !nal.isEmpty { result.append(nal) }
    }
    return result
}
