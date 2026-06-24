import Foundation

let kMagic: UInt32    = 0xDEADC0DE
let kPort: UInt16     = 5054
let kService          = "_epoccam._tcp"

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
