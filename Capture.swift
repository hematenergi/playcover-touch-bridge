import AppKit
import CoreImage
@preconcurrency import ScreenCaptureKit

struct StreamSettings: Codable {
    var fps: Int = 60
    var width: Int = 960
    var quality: Int = 45
    var showTouches: Bool = true
    var valid: Bool { [30, 45, 60].contains(fps) && [640, 960, 1280, 1600].contains(width) && (20...90).contains(quality) }
}

final class TouchView: NSView {
    var points: [[String: Double]] = []
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        for point in points {
            guard let x = point["x"], let y = point["y"] else { continue }
            let rect = NSRect(x: x * bounds.width - 18, y: y * bounds.height - 18, width: 36, height: 36)
            let ring = NSBezierPath(ovalIn: rect)
            NSColor.black.withAlphaComponent(0.8).setStroke(); ring.lineWidth = 5; ring.stroke()
            NSColor.systemCyan.setStroke(); ring.lineWidth = 3; ring.stroke()
            NSColor.systemCyan.withAlphaComponent(0.12).setFill(); ring.fill()
            let label = "\(Int(point["id", default: 0]) + 1)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.white, .strokeColor: NSColor.black, .strokeWidth: -3]
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
        }
    }
}

@MainActor final class TouchOverlay {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let view = TouchView()
    let windowID: CGWindowID
    let pid: Int32
    let aspect: Double
    var enabled = true
    var lastUpdate = Date.distantPast
    init(window: SCWindow, pid: Int32, aspect: Double) {
        windowID = window.windowID; self.pid = pid; self.aspect = aspect
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = view
    }
    func update(_ points: [[String: Double]]) {
        lastUpdate = Date(); view.points = points; refresh()
    }
    func refresh() {
        guard enabled, !view.points.isEmpty, Date().timeIntervalSince(lastUpdate) < 2,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let infos = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let info = infos.first, let raw = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: raw) else { panel.orderOut(nil); return }
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? 0
        let height = rect.width / aspect
        panel.setFrame(NSRect(x: rect.minX, y: desktopTop - rect.maxY, width: rect.width, height: height), display: false)
        view.needsDisplay = true
        panel.orderFrontRegardless()
    }
}

// Mutable encoder state and stdout are confined to queue.
final class Frames: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let context = CIContext(options: [.cacheIntermediates: false])
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let queue = DispatchQueue(label: "playtouch.frames", qos: .userInteractive)
    var quality = 0.45
    func acknowledge(_ settings: StreamSettings) {
        let payload: [String: Any] = ["type": "settings", "settings": ["fps": settings.fps, "width": settings.width, "quality": settings.quality, "showTouches": settings.showTouches]]
        if let data = try? JSONSerialization.data(withJSONObject: payload) { queue.async { self.emit(data) } }
    }
    func emit(_ data: Data) {
        var length = UInt32(data.count).bigEndian
        do {
            try FileHandle.standardOutput.write(contentsOf: withUnsafeBytes(of: &length) { Data($0) })
            try FileHandle.standardOutput.write(contentsOf: data)
        } catch { exit(0) }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sample.imageBuffer else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let jpeg = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]) else { return }
        emit(jpeg)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("Capture stopped: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

@MainActor final class CaptureControls {
    let stream: SCStream
    let config: SCStreamConfiguration
    let output: Frames
    let overlay: TouchOverlay
    let aspect: Double
    init(stream: SCStream, config: SCStreamConfiguration, output: Frames, overlay: TouchOverlay, aspect: Double) {
        self.stream = stream; self.config = config; self.output = output; self.overlay = overlay; self.aspect = aspect
    }
    func apply(_ settings: StreamSettings) async {
        config.width = settings.width
        config.height = Int(Double(settings.width) / aspect)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.fps))
        do {
            try await stream.updateConfiguration(config)
            output.queue.sync { output.quality = Double(settings.quality) / 100 }
            overlay.enabled = settings.showTouches; overlay.refresh()
            output.acknowledge(settings)
        } catch { fputs("Settings: \(error.localizedDescription)\n", stderr) }
    }
}

@main struct Capture {
    static func main() async {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        guard CommandLine.arguments.count == 5,
              let pid = Int32(CommandLine.arguments[1]),
              let gameWidth = Double(CommandLine.arguments[2]),
              let gameHeight = Double(CommandLine.arguments[3]), gameWidth > 0, gameHeight > 0,
              let settingsData = CommandLine.arguments[4].data(using: .utf8),
              let initial = try? JSONDecoder().decode(StreamSettings.self, from: settingsData), initial.valid else { exit(2) }
        do {
            var selected: SCWindow?
            // The splash window is 500x500; wait for the actual game window.
            for _ in 0..<60 {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                selected = content.windows.filter {
                    $0.owningApplication?.processID == pid && $0.frame.width > 600 &&
                    abs($0.frame.width / $0.frame.height - gameWidth / gameHeight) < 0.25
                }.max(by: { $0.frame.width < $1.frame.width })
                if selected != nil { break }
                try await Task.sleep(for: .milliseconds(500))
            }
            guard let window = selected else {
                fputs("HSR capture window not found\n", stderr); exit(1)
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            let contentHeight = window.frame.width * gameHeight / gameWidth
            let titleBar = max(0, window.frame.height - contentHeight)
            config.sourceRect = CGRect(x: 0, y: titleBar, width: window.frame.width, height: contentHeight)
            config.width = initial.width
            config.height = Int(Double(initial.width) * gameHeight / gameWidth)
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(initial.fps))
            config.queueDepth = 3
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            config.capturesAudio = false
            config.ignoreShadowsSingleWindow = true
            fputs("Capture window \(window.windowID), \(window.frame), crop top \(titleBar)\n", stderr)
            let output = Frames()
            output.quality = Double(initial.quality) / 100
            let overlay = TouchOverlay(window: window, pid: pid, aspect: gameWidth / gameHeight)
            overlay.enabled = initial.showTouches
            _ = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                Task { @MainActor in overlay.refresh() }
            }
            let stream = SCStream(filter: filter, configuration: config, delegate: output)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
            try await stream.startCapture()
            let controls = CaptureControls(stream: stream, config: config, output: output, overlay: overlay, aspect: gameWidth / gameHeight)
            output.acknowledge(initial)
            Thread.detachNewThread {
                while let line = readLine() {
                    guard let data = line.data(using: .utf8),
                          let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    if command["type"] as? String == "touches", let points = command["points"] as? [[String: Double]] {
                        Task { @MainActor in overlay.update(points) }
                    } else if command["type"] as? String == "settings", let raw = command["settings"],
                              let json = try? JSONSerialization.data(withJSONObject: raw),
                              let next = try? JSONDecoder().decode(StreamSettings.self, from: json), next.valid {
                        Task { await controls.apply(next) }
                    }
                }
                exit(0)
            }
            while true { try await Task.sleep(for: .seconds(3600)) }
        } catch {
            fputs("Capture: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
