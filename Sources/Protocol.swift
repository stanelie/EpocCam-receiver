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

    // Per-slot UserDefaults key for the last selected format. (lastHostKey/lastPortKey
    // used to live here too, for the "last-known host" fast-start probe that was removed
    // — it raced mDNS and opened a second socket to the same phone. Nothing read them.)
    var lastFormatKey: String { "EpocCamLastFormat.\(label)" }
    // Digital stabilization choice, persisted per slot and re-applied when a phone connects
    // — the same way the resolution choice is.
    var stabilizationKey: String { "EpocCamStabilization.\(label)" }
    // Capture frame rate, persisted per slot and re-applied on connect — same as the two above.
    var frameRateKey: String { "EpocCamFrameRate.\(label)" }

    static func from(role: String?) -> CameraSlot? {
        switch role?.lowercased() {
        case "a": return .a
        case "b": return .b
        default:  return nil
        }
    }
}

// What a phone's focus is actually doing. Mirrors FOCUS_STATE_* on the streamer — the
// viewer never infers this, it is reported.
enum FocusState: Int {
    case auto = 0, manual = 1, busy = 2, unsure = 3

    // Same wording as the phone's own button, so the two read identically.
    var label: String {
        switch self {
        case .auto:   return "auto\nfocus"
        case .manual: return "manual\nfocus"
        case .busy:   return "focusing\n…"
        case .unsure: return "manual\nfocus?"
        }
    }
    var isManual: Bool { self != .auto }
}

// What a phone reports about its stabilization. Capability travels with state so the viewer
// can hide the control on a camera that can't do it, rather than offering a dead button.
struct StabilizationState {
    var eisSupported = false
    var eisOn        = false
    var oisSupported = false
    var oisOn        = false
}

enum PktType: UInt32 {
    case video      = 0x00020002
    case fmtSelect  = 0x00020003
    case audio      = 0x00020004
    case capability = 0x00020005
    case battery    = 0x00020006  // not in the original iPhone/Android wire protocol — our own
    case torch      = 0x00020007  // ditto: viewer -> phone, toggles the camera LED
    case focusCmd   = 0x00020008  // viewer -> phone: set focus mode / trigger a refocus
    case focusState = 0x00020009  // phone -> viewer: what the phone's focus is actually doing
    case stabCmd    = 0x0002000A  // viewer -> phone: electronic stabilization on/off
    case stabState  = 0x0002000B  // phone -> viewer: stabilization capability + state
    case fpsCmd     = 0x0002000C  // viewer -> phone: capture/encode frame rate
    case fpsState   = 0x0002000D  // phone -> viewer: frame rate in use + 60fps capability
}

// Frame rate the phone actually settled on, plus whether it could do 60 at all — a camera
// that can't sustain it gets the option greyed out rather than silently clamped.
struct FpsState {
    var current   = 30
    var supports60 = false
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

    // Resolution only: the frame rate is a separate menu now, and repeating the
    // connect-time rate here would contradict it the moment the operator changes it.
    var label: String { "\(width)×\(height)" }
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

    // Focus commands, viewer → phone. Must match FOCUS_CMD_* on the streamer.
    enum FocusCommand: UInt8 { case auto = 0, manual = 1, refocus = 2 }

    // Build an electronic-stabilization command, viewer → phone. (There is no OIS command:
    // optical stabilization costs nothing, so the phone just enables it wherever present.)
    static func stabilizationPacket(on: Bool) -> Data {
        var p = Data(count: 256)
        p.putLeU32(kMagic,                    at: 0)
        p.putLeU32(0,                         at: 4)
        p.putLeU32(PktType.stabCmd.rawValue,  at: 8)
        p.putLeU32(UInt32(244),               at: 12)
        p[16] = on ? 1 : 0
        return p
    }

    // Build a focus-command packet, viewer → phone. Same 256-byte shape as format-select
    // for the same reason: the phone reads fixed offsets from a single read.
    static func focusCommandPacket(_ cmd: FocusCommand) -> Data {
        var p = Data(count: 256)
        p.putLeU32(kMagic,                     at: 0)
        p.putLeU32(0,                          at: 4)
        p.putLeU32(PktType.focusCmd.rawValue,  at: 8)
        p.putLeU32(UInt32(244),                at: 12)
        p[16] = cmd.rawValue
        return p
    }

    // Build a torch (camera LED) packet, viewer → streamer. Same 256-byte shape as
    // format-select because the phone's receive path assumes one packet per read and
    // pulls its fields from fixed offsets; matching that layout keeps it safe.
    static func torchPacket(on: Bool) -> Data {
        var p = Data(count: 256)
        p.putLeU32(kMagic,                  at: 0)
        p.putLeU32(0,                       at: 4)
        p.putLeU32(PktType.torch.rawValue,  at: 8)
        p.putLeU32(UInt32(244),             at: 12)  // remaining bytes
        p[16] = on ? 1 : 0
        return p
    }

    // Build a frame-rate packet, viewer → phone. Same 256-byte shape as the others so the
    // phone's fixed-offset read path stays uniform.
    static func fpsPacket(_ fps: Int) -> Data {
        var p = Data(count: 256)
        p.putLeU32(kMagic,                   at: 0)
        p.putLeU32(0,                        at: 4)
        p.putLeU32(PktType.fpsCmd.rawValue,  at: 8)
        p.putLeU32(UInt32(244),              at: 12)
        p[16] = UInt8(clamping: fps)
        return p
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

// Does this Annex-B buffer contain an IDR (NAL type 5)? NDI needs each compressed frame
// flagged as a keyframe or not. Scans start codes directly rather than splitting the whole
// buffer, since this runs on every frame.
func annexBContainsIDR(_ data: Data) -> Bool {
    let b = data.startIndex == 0 ? data : Data(data)
    var i = 0
    while i + 3 < b.count {
        if b[i] == 0, b[i+1] == 0 {
            var nal = -1
            if b[i+2] == 1 { nal = i + 3 }
            else if b[i+2] == 0, i + 4 < b.count, b[i+3] == 1 { nal = i + 4 }
            if nal >= 0, nal < b.count {
                if (b[nal] & 0x1F) == 5 { return true }
                i = nal
                continue
            }
        }
        i += 1
    }
    return false
}

// Pull just the SPS (7) and PPS (8) NALs out, re-emitted with 4-byte start codes. NDI wants
// these as a keyframe's "extra data".
func extractParameterSets(_ data: Data) -> Data? {
    var out = Data()
    for nal in splitAnnexB(data) where !nal.isEmpty {
        let t = Int(nal[nal.startIndex] & 0x1F)
        if t == 7 || t == 8 {
            out.append(contentsOf: [0, 0, 0, 1])
            out.append(nal)
        }
    }
    return out.isEmpty ? nil : out
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
