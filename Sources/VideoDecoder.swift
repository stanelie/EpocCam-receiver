import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

final class VideoDecoder {
    var onFrame: ((CVPixelBuffer) -> Void)?

    private var session:    VTDecompressionSession?
    private var formatDesc: CMVideoFormatDescription?
    private var needsReset  = false

    // Called for every incoming video packet payload + flags
    func handle(payload: Data, flags: UInt32) {
        // Decoder-reset signal
        if payload == kResetPayload {
            NSLog("EpocCam: decoder reset signal received")
            invalidateSession()
            needsReset = true
            return
        }

        // Config-only packet (SPS+PPS, flags bit 0x08)
        if flags & kFlagConfig != 0 {
            NSLog("EpocCam: config packet (SPS/PPS) received (%d bytes)", payload.count)
            rebuildFormat(annexB: payload)
            return
        }

        // Annex-B bundle (SPS+PPS+IDR) – starts with 00 00 01 or 00 00 00 01
        if payload.count > 3, payload[0] == 0, payload[1] == 0, payload[2] == 1 {
            NSLog("EpocCam: Annex-B bundle received (%d bytes)", payload.count)
            handleBundle(annexB: payload)
            return
        }
        if payload.count > 4, payload[0] == 0, payload[1] == 0,
           payload[2] == 0, payload[3] == 1
        {
            NSLog("EpocCam: Annex-B bundle (4-byte SC) received (%d bytes)", payload.count)
            handleBundle(annexB: payload)
            return
        }

        // Raw NAL unit
        decode(nal: payload)
    }

    // MARK: - Private

    private func handleBundle(annexB: Data) {
        let nals = splitAnnexB(annexB)
        var sps: Data?, pps: Data?
        var videoNals: [Data] = []
        for nal in nals {
            guard !nal.isEmpty else { continue }
            let t = Int(nal[0] & 0x1F)
            switch t {
            case 7: sps = nal
            case 8: pps = nal
            case 1, 5: videoNals.append(nal)
            default: break
            }
        }
        if let s = sps, let p = pps {
            rebuildFormat(sps: s, pps: p)
        }
        for nal in videoNals {
            decode(nal: nal)
        }
    }

    private func rebuildFormat(annexB: Data) {
        let nals = splitAnnexB(annexB)
        var sps: Data?, pps: Data?
        for nal in nals {
            guard !nal.isEmpty else { continue }
            let t = Int(nal[0] & 0x1F)
            if t == 7 { sps = nal }
            if t == 8 { pps = nal }
        }
        guard let s = sps, let p = pps else { return }
        rebuildFormat(sps: s, pps: p)
    }

    private func rebuildFormat(sps: Data, pps: Data) {
        NSLog("EpocCam: rebuilding format - SPS %d bytes, PPS %d bytes", sps.count, pps.count)
        invalidateSession()
        var desc: CMVideoFormatDescription?
        sps.withUnsafeBytes { spsPtr in
            pps.withUnsafeBytes { ppsPtr in
                let paramSets: [UnsafePointer<UInt8>] = [
                    spsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ppsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                ]
                let sizes: [Int] = [sps.count, pps.count]
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: paramSets,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &desc
                )
            }
        }
        if desc == nil {
            NSLog("EpocCam: ERROR - CMVideoFormatDescriptionCreateFromH264ParameterSets failed")
            return
        }
        formatDesc = desc
        createSession(formatDesc: desc!)
        NSLog("EpocCam: VT session created OK")
        needsReset = false
    }

    private func createSession(formatDesc: CMVideoFormatDescription) {
        let attrs: [NSString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [NSString: Any]
        ]
        var newSession: VTDecompressionSession?
        VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &newSession
        )
        session = newSession
    }

    private func decode(nal: Data) {
        guard !needsReset,
              let session,
              let formatDesc else { return }

        // Wrap NAL in AVCC format: 4-byte big-endian length prefix
        let lengthBE = UInt32(nal.count).bigEndian
        var avcc = Data(capacity: 4 + nal.count)
        withUnsafeBytes(of: lengthBE) { avcc.append(contentsOf: $0) }
        avcc.append(nal)

        // Allocate a CMBlockBuffer that owns its memory (safe for async decode).
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator:         kCFAllocatorDefault,
            memoryBlock:       nil,          // allocate new memory
            blockLength:       avcc.count,
            blockAllocator:    nil,
            customBlockSource: nil,
            offsetToData:      0,
            dataLength:        avcc.count,
            flags:             0,
            blockBufferOut:    &block
        ) == noErr, let block else { return }

        guard avcc.withUnsafeBytes({ ptr in
            CMBlockBufferReplaceDataBytes(
                with: ptr.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            )
        }) == noErr else { return }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleSize = avcc.count
        guard CMSampleBufferCreate(
            allocator:             kCFAllocatorDefault,
            dataBuffer:            block,
            dataReady:             true,
            makeDataReadyCallback: nil,
            refcon:                nil,
            formatDescription:     formatDesc,
            sampleCount:           1,
            sampleTimingEntryCount: 1,
            sampleTimingArray:     &timing,
            sampleSizeEntryCount:  1,
            sampleSizeArray:       &sampleSize,
            sampleBufferOut:       &sampleBuffer
        ) == noErr, let sampleBuffer else { return }

        let me = self
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            infoFlagsOut: nil
        ) { status, _, imageBuffer, _, _ in
            if status != noErr {
                NSLog("EpocCam: decode error %d", status)
                return
            }
            guard let imageBuffer else { return }
            me.onFrame?(imageBuffer)
        }
        if decodeStatus != noErr {
            NSLog("EpocCam: VTDecompressionSessionDecodeFrame error %d", decodeStatus)
        }
    }

    private func invalidateSession() {
        if let s = session { VTDecompressionSessionInvalidate(s) }
        session = nil
        formatDesc = nil
    }
}
