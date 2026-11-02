import BlechWikiCore
import ImageIO
import UIKit

/// Lädt Cover und schneidet weiße Ränder ab (siehe `CoverTrimmer`). Ersetzt `AsyncImage`, das
/// Bilder nur unverändert anzeigen kann. Platte bleibt der gemeinsame `URLCache`, im Speicher
/// liegen die fertig zugeschnittenen Bilder.
///
/// Die Originale haben oft mehrere tausend Pixel Kantenlänge. Dekodiert wird deshalb gleich auf
/// die Anzeigegröße (`maxPixelSize`, längere Kante), der Speicher-Cache ist nach Bytes begrenzt.
enum CoverLoader {

    /// Längere Kante im Vollbild. Reicht für das größte iPad hochkant (2752 px), ohne dass ein
    /// Original mit 6000 px ungebremst im Speicher landet.
    static let fullScreenPixelSize = 2800

    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        // Etwa 400 Listen-Cover oder 4 Vollbild-Cover
        cache.totalCostLimit = 80 * 1024 * 1024
        return cache
    }()

    /// Pixel für ein Cover mit `height` Punkten Höhe. Mit Faktor 3 (größter Bildschirm-Faktor)
    /// und Reserve für den Zuschnitt, auf 64 px aufgerundet, damit gleich große Cover sich den
    /// Cache-Eintrag teilen. Ohne Umgebung berechenbar, damit `CoverImage` schon im `init` nachsehen kann.
    static func pixelSize(height: CGFloat) -> Int {
        let pixels = Int((height * 3 * 1.25).rounded(.up))
        return (pixels + 63) / 64 * 64
    }

    static func cached(_ url: URL, maxPixelSize: Int) -> UIImage? {
        cache.object(forKey: key(url, maxPixelSize))
    }

    static func load(_ url: URL, maxPixelSize: Int) async throws -> UIImage {
        if let image = cached(url, maxPixelSize: maxPixelSize) { return image }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        let image = try await Task.detached(priority: .userInitiated) { try decodeAndTrim(data, maxPixelSize: maxPixelSize) }.value
        let cost = (image.cgImage.map { $0.bytesPerRow * $0.height }) ?? 0
        cache.setObject(image, forKey: key(url, maxPixelSize), cost: cost)
        return image
    }

    private static func key(_ url: URL, _ maxPixelSize: Int) -> NSString {
        "\(maxPixelSize)|\(url.absoluteString)" as NSString
    }

    private nonisolated static func decodeAndTrim(_ data: Data, maxPixelSize: Int) throws -> UIImage {
        // Verkleinert beim Dekodieren, kleinere Bilder bleiben unverändert. Dreht nach EXIF wie UIImage.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw URLError(.cannotDecodeContentData) }
        return UIImage(cgImage: CoverTrimmer.trimmed(cgImage) ?? cgImage)
    }
}
