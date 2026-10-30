import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import BlechWikiCore

struct CoverTrimmerTests {

    private func image(width: Int, height: Int, background: CGColor, rect: CGRect?) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(background)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let rect {
            ctx.setFillColor(CGColor(red: 0.3, green: 0.2, blue: 0.4, alpha: 1))
            // CGContext zeichnet von unten, Testangaben sind von oben gemeint
            ctx.fill(CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height))
        }
        return ctx.makeImage()!
    }

    private let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

    @Test func schneidetWeissenRandAb() throws {
        let source = image(width: 800, height: 800, background: white, rect: CGRect(x: 270, y: 220, width: 260, height: 360))
        let trimmed = try #require(CoverTrimmer.trimmed(source))
        // Erkennung auf 160 px, daher ± eine Analysezeile (5 px)
        #expect(abs(trimmed.width - 260) <= 10)
        #expect(abs(trimmed.height - 360) <= 10)
    }

    @Test func randOben() throws {
        // Motiv nur in der unteren Hälfte: prüft, dass oben und unten nicht vertauscht sind
        let source = image(width: 400, height: 400, background: white, rect: CGRect(x: 0, y: 200, width: 400, height: 200))
        let box = try #require(CoverTrimmer.contentBox(source))
        #expect(abs(box.minY - 200) <= 5)
        #expect(abs(box.height - 200) <= 5)
    }

    @Test func coverOhneRandBleibt() {
        let source = image(width: 120, height: 170, background: CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1), rect: nil)
        #expect(CoverTrimmer.trimmed(source) == nil)
    }

    @Test func leeresWeissesBildBleibt() {
        #expect(CoverTrimmer.trimmed(image(width: 100, height: 100, background: white, rect: nil)) == nil)
    }

    /// Echtes Cover vom Bildserver: 800 × 800, Heft in der Mitte.
    @Test func blaeserfreude() throws {
        let url = Bundle.module.url(forResource: "cover_blaeserfreude.jpg", withExtension: nil, subdirectory: "Fixtures")!
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let cover = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let trimmed = try #require(CoverTrimmer.trimmed(cover))
        let ratio = Double(trimmed.height) / Double(trimmed.width)
        #expect(trimmed.width < 320)
        #expect(ratio > 1.25 && ratio < 1.5, "Hochformat wie ein Notenheft, war \(trimmed.width) × \(trimmed.height)")
    }
}
