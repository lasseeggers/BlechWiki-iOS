// Skaliert den Video-Export aus Claude Motion (dort nur bis 1080 Pixel Höhe) auf die Größe der
// App-Store-Kopfzeile, 3840×1646, und prüft das Ergebnis. Ohne ffmpeg, nur mit AVFoundation.
//
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
//     swift ios/scripts/appstore/upscale-video.swift <export.mp4> <ziel.mp4>
import AVFoundation

let args = CommandLine.arguments
guard args.count == 3 else { print("Aufruf: upscale-video.swift <quelle.mp4> <ziel.mp4>"); exit(2) }
let src = URL(fileURLWithPath: args[1]), dst = URL(fileURLWithPath: args[2])
let width = 3840.0, height = 1646.0

func describe(_ url: URL) async throws -> (CGSize, Float, Double) {
    let asset = AVURLAsset(url: url)
    let track = try await asset.loadTracks(withMediaType: .video).first!
    return (try await track.load(.naturalSize), try await track.load(.nominalFrameRate), try await asset.load(.duration).seconds)
}

let done = DispatchSemaphore(value: 0)
var failed = false
Task {
    defer { done.signal() }
    do {
        let asset = AVURLAsset(url: src)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let (size, fps, seconds) = try await describe(src)
        print("Quelle \(Int(size.width))x\(Int(size.height)), \(Int(fps.rounded())) fps, \(seconds) s")

        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: width, height: height)
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(CGAffineTransform(scaleX: width / size.width, y: height / size.height), at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]

        let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality)!
        export.videoComposition = composition
        export.outputURL = dst
        export.outputFileType = .mp4
        try? FileManager.default.removeItem(at: dst)
        await export.export()
        guard export.status == .completed else { throw export.error ?? CocoaError(.fileWriteUnknown) }

        let (s, f, d) = try await describe(dst)
        print("Ziel \(Int(s.width))x\(Int(s.height)), \(Int(f.rounded())) fps, \(d) s")
        // Apple: 3840×1646, 5 bis 30 s, 30 oder 60 fps
        if Int(s.width) != 3840 || Int(s.height) != 1646 || d < 5 || d > 30 || ![30, 60].contains(Int(f.rounded())) {
            print("FEHLER: entspricht nicht der Vorgabe für die Kopfzeile"); failed = true
        }
    } catch {
        print("FEHLER: \(error)"); failed = true
    }
}
done.wait()
exit(failed ? 1 : 0)
