import CoreGraphics

/// Manche Cover auf dem Bildserver sind quadratische Produktfotos aus Shops: das Heft klein in der
/// Mitte, rundherum Weiß (z. B. "Bläserfreude", 800 × 800 mit dem Heft auf ca. 260 × 360).
/// Im Hochformat-Rahmen der App bleibt davon fast nur Weiß übrig. Der Trimmer schneidet
/// solche Ränder ab.
public enum CoverTrimmer {

    /// Kanal-Wert, ab dem ein Pixel als Weiß gilt. Unter 255, weil JPEG-Rauschen den Rand sprenkelt.
    static let whiteThreshold: UInt8 = 236
    /// Anteil nicht-weißer Pixel, ab dem eine Zeile oder Spalte zum Motiv zählt.
    /// Verhindert, dass einzelne Staubkörner oder Kompressionsartefakte den Rand halten.
    static let contentFraction = 0.03
    /// Erkennung auf verkleinerter Kopie, das reicht für den Rand und spart Rechenzeit.
    static let analysisSize = 160

    /// Liefert das Bild ohne weißen Rand, oder `nil`, wenn es keinen nennenswerten Rand hat.
    public static func trimmed(_ image: CGImage) -> CGImage? {
        guard let box = contentBox(image) else { return nil }
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        // Unter 10 % Rand lohnt sich das Beschneiden nicht, echte Cover haben oft hellen Hintergrund am Rand
        if box.width * box.height > full.width * full.height * 0.9 { return nil }
        return image.cropping(to: box.integral)
    }

    /// Bereich mit Motiv in Pixeln des Originals (Ursprung oben links), `nil` bei leerem Bild.
    static func contentBox(_ image: CGImage) -> CGRect? {
        let scale = min(1, Double(analysisSize) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale))
        let h = max(1, Int(Double(image.height) * scale))
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            // Transparenz zählt als Weiß
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        var rowCounts = [Int](repeating: 0, count: h)
        var columnCounts = [Int](repeating: 0, count: w)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                if pixels[i] < whiteThreshold || pixels[i + 1] < whiteThreshold || pixels[i + 2] < whiteThreshold {
                    rowCounts[y] += 1
                    columnCounts[x] += 1
                }
            }
        }
        let rows = rowCounts.indices.filter { Double(rowCounts[$0]) >= Double(w) * contentFraction }
        let columns = columnCounts.indices.filter { Double(columnCounts[$0]) >= Double(h) * contentFraction }
        guard let top = rows.first, let bottom = rows.last, let left = columns.first, let right = columns.last else { return nil }

        // Zeile 0 im Puffer ist die oberste Bildzeile (CGContext-Speicher beginnt oben)
        let sx = Double(image.width) / Double(w)
        let sy = Double(image.height) / Double(h)
        return CGRect(
            x: Double(left) * sx,
            y: Double(top) * sy,
            width: Double(right - left + 1) * sx,
            height: Double(bottom - top + 1) * sy
        ).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
}
