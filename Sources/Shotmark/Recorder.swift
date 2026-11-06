import AppKit
import ScreenCaptureKit

/// Запись экрана или области в MP4 через SCRecordingOutput.
@MainActor
final class Recorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    static let shared = Recorder()
    private var stream: SCStream?
    private(set) var url: URL?
    private var finished: CheckedContinuation<Void, Never>?
    var onChange: () -> Void = {}

    var isRecording: Bool { stream != nil }

    /// rect — глобальные точки (слева сверху); nil — весь монитор с курсором или с номером display.
    func start(rect: CGRect?, display index: Int? = nil) async throws -> URL {
        guard stream == nil else { throw ShotError("запись уже идёт: \(url?.path ?? "")") }
        let c = try await Capture.content()
        let d: SCDisplay?
        if let rect {
            d = c.displays.first { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }
        } else if let index {
            d = index >= 0 && index < c.displays.count ? c.displays[index] : nil
        } else {
            let m = NSEvent.mouseLocation
            let id = NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) }?.displayID
            d = c.displays.first { $0.displayID == id } ?? c.displays.first
        }
        guard let d else { throw ShotError("монитор для записи не найден") }
        let local = (rect ?? d.frame).intersection(d.frame).offsetBy(dx: -d.frame.minX, dy: -d.frame.minY)
        let scale = Capture.scale(d.displayID)
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = local
        cfg.width = Int(local.width * scale) / 2 * 2      // H.264 любит чётные размеры
        cfg.height = Int(local.height * scale) / 2 * 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        cfg.showsCursor = true
        let own = c.applications.filter { $0.processID == getpid() }
        let s = SCStream(filter: SCContentFilter(display: d, excludingApplications: own, exceptingWindows: []),
                         configuration: cfg, delegate: self)
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Shotmark")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let out = dir.appendingPathComponent("rec-\(f.string(from: Date())).mp4")
        let rc = SCRecordingOutputConfiguration()
        rc.outputURL = out
        rc.outputFileType = .mp4
        rc.videoCodecType = .h264
        try s.addRecordingOutput(SCRecordingOutput(configuration: rc, delegate: self))
        try await s.startCapture()
        stream = s
        url = out
        onChange()
        return out
    }

    func stop() async throws -> URL {
        guard let s = stream, let out = url else { throw ShotError("запись не идёт") }
        await withCheckedContinuation { c in
            finished = c
            Task {
                try? await s.stopCapture()
                // страховка, если делегат не позовёт recordingOutputDidFinishRecording
                try? await Task.sleep(for: .seconds(3))
                self.finish()
            }
        }
        stream = nil
        onChange()
        return out
    }

    private func finish() { finished?.resume(); finished = nil }

    nonisolated func recordingOutputDidFinishRecording(_ o: SCRecordingOutput) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func recordingOutput(_ o: SCRecordingOutput, didFailWithError error: Error) {
        NSLog("Shotmark: запись прервана: \(error)")
        Task { @MainActor in self.finish() }
    }

    nonisolated func stream(_ s: SCStream, didStopWithError error: Error) {
        NSLog("Shotmark: поток остановлен: \(error)")
        Task { @MainActor in
            self.finish()
            if self.stream === s { self.stream = nil; self.onChange() }
        }
    }
}
