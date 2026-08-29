import AppKit
import AVFoundation
import CoreMedia
import CoreVideo

// Displays decoded video frames using AVSampleBufferDisplayLayer.
final class VideoView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    // At most one frame waiting for the main thread, newest wins. A live preview only ever
    // wants the latest frame: dispatching every decoded frame lets the main queue grow
    // without bound whenever it can't keep up (two phones at 30+60fps put 90 blocks/sec on
    // it, each retaining a pixel buffer), and the picture then drifts steadily further
    // behind with no way to recover. Dropping a superseded frame costs nothing visible.
    private let pendingLock = NSLock()
    private var pending: CVPixelBuffer?
    private var scheduled = false
    // How often a frame is superseded before it could be drawn — i.e. how far behind the
    // main thread is running. Zero means it keeps up; a steady non-zero rate is the signal
    // that the display path is the bottleneck (under the old unbounded dispatch these were
    // not dropped but queued, which is what made the picture drift further behind over time).
    private var superseded = 0
    private var lastDropLog = CFAbsoluteTimeGetCurrent()
    var label = "?" 

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer = displayLayer
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor

        // Use a timebase running at 1x from now so frames with "current" timestamps
        // are displayed immediately.
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )
        if let tb = timebase {
            // Align timebase with the host clock so frame PTSes (also from the host clock)
            // are displayed immediately rather than deferred to a far-future time.
            CMTimebaseSetTime(tb, time: CMClockGetTime(CMClockGetHostTimeClock()))
            CMTimebaseSetRate(tb, rate: 1.0)
            displayLayer.controlTimebase = tb
        }
    }

    // Clear any displayed frame back to black (e.g. when a slot loses its feed).
    func clear() {
        pendingLock.lock(); pending = nil; pendingLock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.displayLayer.flushAndRemoveImage()
        }
    }

    // Call from any thread; coalesces onto main.
    func display(pixelBuffer: CVPixelBuffer) {
        pendingLock.lock()
        if pending != nil { superseded += 1 }
        pending = pixelBuffer          // supersedes any frame not yet drawn
        let needsSchedule = !scheduled
        scheduled = true
        let now = CFAbsoluteTimeGetCurrent()
        var report: (Int, Double)? = nil
        if now - lastDropLog >= 5.0 {
            report = (superseded, now - lastDropLog)
            superseded = 0
            lastDropLog = now
        }
        pendingLock.unlock()
        if let (n, secs) = report, n > 0 {
            NSLog("EpocCam[%@] display: %d frames superseded in %.1fs (main thread behind)",
                  label, n, secs)
        }
        guard needsSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingLock.lock()
            let buf = self.pending
            self.pending = nil
            self.scheduled = false
            self.pendingLock.unlock()
            if let buf { self.enqueue(buf) }
        }
    }

    private func enqueue(_ pixelBuffer: CVPixelBuffer) {
        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        )
        guard let formatDesc else { return }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDesc,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard let sampleBuffer else { return }

        if displayLayer.status == .failed { displayLayer.flush() }
        // Drop rather than queue behind a layer that is already backed up: the next frame is
        // along in a few ms and is more current than anything waiting.
        guard displayLayer.isReadyForMoreMediaData else { return }
        displayLayer.enqueue(sampleBuffer)
    }
}
