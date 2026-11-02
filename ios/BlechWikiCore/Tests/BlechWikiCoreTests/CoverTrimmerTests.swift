import CoreGraphics
import Foundation
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

    /// Wie `CoverTrim` auf Android: Unter halber Deckkraft zählt ein Pixel als Weiß, egal welche Farbe.
    @Test func halbtransparenterRandZaehltAlsWeiss() throws {
        let source = image(width: 100, height: 100, background: CGColor(red: 0, green: 0, blue: 0, alpha: 0.37),
                           rect: CGRect(x: 25, y: 25, width: 50, height: 50))
        #expect(try #require(CoverTrimmer.contentBox(source)) == CGRect(x: 25, y: 25, width: 50, height: 50))
    }

    @Test func transparenterRandZaehltAlsWeiss() throws {
        let source = image(width: 100, height: 100, background: CGColor(red: 0, green: 0, blue: 0, alpha: 0),
                           rect: CGRect(x: 25, y: 25, width: 50, height: 50))
        #expect(try #require(CoverTrimmer.contentBox(source)) == CGRect(x: 25, y: 25, width: 50, height: 50))
    }

    /// Ab halber Deckkraft zählt die Farbe selbst, nicht gemischt mit Weiß: Hellgrau (230) mit 60 %
    /// Deckkraft ist Motiv, obwohl es über Weiß gelegt heller als die Schwelle wäre.
    @Test func deckendesHellgrauIstMotiv() {
        let gray = CGColor(red: 230.0 / 255, green: 230.0 / 255, blue: 230.0 / 255, alpha: 0.6)
        #expect(CoverTrimmer.trimmed(image(width: 100, height: 100, background: gray, rect: nil)) == nil)
        #expect(CoverTrimmer.contentBox(image(width: 100, height: 100, background: gray, rect: nil)) == CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    @Test func einPixel() {
        let source = image(width: 1, height: 1, background: CGColor(red: 0, green: 0, blue: 0, alpha: 1), rect: nil)
        #expect(CoverTrimmer.contentBox(source) == CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(CoverTrimmer.trimmed(source) == nil)
    }

    /// Bei 5000 px Kantenlänge steht eine Analysezeile für gut 31 px.
    @Test func extremeSeitenverhaeltnisse() throws {
        let tall = try #require(CoverTrimmer.trimmed(image(width: 1, height: 5000, background: white, rect: CGRect(x: 0, y: 2000, width: 1, height: 1000))))
        #expect(tall.width == 1)
        #expect(abs(tall.height - 1000) <= 63)

        let wide = try #require(CoverTrimmer.contentBox(image(width: 5000, height: 3, background: white, rect: CGRect(x: 2000, y: 0, width: 500, height: 3))))
        #expect(abs(wide.minX - 2000) <= 32)
        #expect(abs(wide.width - 500) <= 63)
        #expect(wide.height == 3)
    }

    /// Nachbau eines Shop-Produktfotos wie "Bläserfreude" auf dem Bildserver: 800 × 800, fast weißer
    /// Hintergrund mit Rauschen und Staub, das Heft (260 × 360) mit Schlagschatten in der Mitte.
    /// Selbst gezeichnet statt des echten Covers, das nicht ins öffentliche Repo darf.
    @Test func produktfotoMitHeftInDerMitte() throws {
        let size = 800
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Feste Folge statt Zufall, damit der Test immer dasselbe Bild prüft
        var seed: UInt32 = 1
        func next(_ range: Int) -> Int {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Int(seed >> 8) % range
        }
        // Rauschen wie bei JPEG: Kacheln knapp unter Reinweiß, alle über der Schwelle
        for y in stride(from: 0, to: size, by: 8) {
            for x in stride(from: 0, to: size, by: 8) {
                let v = CGFloat(240 + next(16)) / 255
                ctx.setFillColor(CGColor(red: v, green: v, blue: v, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: 8, height: 8))
            }
        }
        // Staubkörner im Rand
        ctx.setFillColor(CGColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1))
        for _ in 0..<60 {
            ctx.fill(CGRect(x: next(size), y: next(size), width: 2, height: 2))
        }
        // Heft oben links bei (270, 220), CGContext zählt y von unten
        let booklet = CGRect(x: 270, y: size - 220 - 360, width: 260, height: 360)
        ctx.setFillColor(CGColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1))
        ctx.fill(booklet.offsetBy(dx: 6, dy: -6))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.25, blue: 0.55, alpha: 1))
        ctx.fill(booklet)
        ctx.setFillColor(CGColor(red: 0.95, green: 0.75, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: booklet.minX + 30, y: booklet.minY + 120, width: 200, height: 120))
        let cover = ctx.makeImage()!

        let trimmed = try #require(CoverTrimmer.trimmed(cover))
        let ratio = Double(trimmed.height) / Double(trimmed.width)
        #expect(trimmed.width < 320)
        #expect(ratio > 1.25 && ratio < 1.5, "Hochformat wie ein Notenheft, war \(trimmed.width) × \(trimmed.height)")
        let box = try #require(CoverTrimmer.contentBox(cover))
        #expect(abs(box.midX - 400) < 40)
    }
}
