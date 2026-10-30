import BlechWikiCore
import UIKit

/// Lädt Cover und schneidet weiße Ränder ab (siehe `CoverTrimmer`). Ersetzt `AsyncImage`, das
/// Bilder nur unverändert anzeigen kann. Platte bleibt der gemeinsame `URLCache`, im Speicher
/// liegen die fertig zugeschnittenen Bilder.
enum CoverLoader {

    private static let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 300
        return cache
    }()

    static func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    static func load(_ url: URL) async throws -> UIImage {
        if let image = cached(url) { return image }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        let image = try await Task.detached(priority: .userInitiated) { try decodeAndTrim(data) }.value
        cache.setObject(image, forKey: url as NSURL)
        return image
    }

    private nonisolated static func decodeAndTrim(_ data: Data) throws -> UIImage {
        guard let image = UIImage(data: data), let cgImage = image.cgImage else { throw URLError(.cannotDecodeContentData) }
        guard let trimmed = CoverTrimmer.trimmed(cgImage) else { return image }
        return UIImage(cgImage: trimmed, scale: image.scale, orientation: image.imageOrientation)
    }
}
