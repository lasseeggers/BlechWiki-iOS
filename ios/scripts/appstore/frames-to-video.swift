// Setzt Einzelbilder (PNG, f0000.png, f0001.png …) zu einem MP4 zusammen und prüft das Ergebnis
// gegen die Vorgaben der App-Store-Kopfzeile. Für die 4K-Fassung des Videos aus Claude Motion:
// Der Export dort geht nur bis 1080 Pixel Höhe, der Renderer des Motion-Typs liefert die Bilder
// aber in voller Größe (siehe .claude/skills/appstore-medien/SKILL.md). Ohne ffmpeg, nur AVFoundation.
//
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
//     swift ios/scripts/appstore/frames-to-video.swift <ordner mit pngs> <fps> <ziel.mp4>
import AVFoundation
import CoreImage
import ImageIO

let args = CommandLine.arguments
guard args.count == 4, let fps = Int32(args[2]) else { print("Aufruf: frames-to-video.swift <ordner> <fps> <ziel.mp4>"); exit(2) }
let dir = URL(fileURLWithPath: args[1]), dst = URL(fileURLWithPath: args[3])
let frames = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
guard let first = frames.first, let probe = CGImageSourceCreateWithURL(first as CFURL, nil),
      let firstImage = CGImageSourceCreateImageAtIndex(probe, 0, nil) else { print("FEHLER: keine PNGs in \(dir.path)"); exit(1) }
let width = firstImage.width, height = firstImage.height
print("\(frames.count) Bilder, \(width)x\(height), \(fps) fps")

// Ohne Zielordner liefert AVAssetWriter keinen Puffer und das erste Bild scheitert
try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
try? FileManager.default.removeItem(at: dst)
let writer = try AVAssetWriter(outputURL: dst, fileType: .mp4)
// H.264 wie bei App-Vorschauvideos verlangt. 3840 Breite braucht High Profile ab Level 5.1
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 40_000_000,
        AVVideoExpectedSourceFrameRateKey: fps,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
    ],
])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height,
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let context = CIContext()
for (i, url) in frames.enumerated() {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
    guard let image = CIImage(contentsOf: url), let pool = adaptor.pixelBufferPool else { print("FEHLER: \(url.lastPathComponent)"); exit(1) }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
    context.render(image, to: buffer!, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
    if i % 60 == 0 { print("Bild \(i)/\(frames.count)") }
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
guard writer.status == .completed else { print("FEHLER: \(writer.error.map { "\($0)" } ?? "unbekannt")"); exit(1) }

let asset = AVURLAsset(url: dst)
let check = DispatchSemaphore(value: 0)
var failed = false
Task {
    defer { check.signal() }
    let track = try await asset.loadTracks(withMediaType: .video).first!
    let size = try await track.load(.naturalSize), rate = try await track.load(.nominalFrameRate), seconds = try await asset.load(.duration).seconds
    print("Ziel \(Int(size.width))x\(Int(size.height)), \(Int(rate.rounded())) fps, \(seconds) s")
    // Apple: 3840×1646, 5 bis 30 s, 30 oder 60 fps
    if Int(size.width) != 3840 || Int(size.height) != 1646 || seconds < 5 || seconds > 30 || ![30, 60].contains(Int(rate.rounded())) {
        print("FEHLER: entspricht nicht der Vorgabe für die Kopfzeile"); failed = true
    }
}
check.wait()
exit(failed ? 1 : 0)
