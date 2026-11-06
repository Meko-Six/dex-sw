import CoreGraphics
import DexCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What the track window shows from a file's tags: the names and the cover.
/// Read on every load and kept only while the deck holds the track, as
/// `useArt` does.
public struct TrackTags: @unchecked Sendable {
    public var artist: String?
    public var title: String?
    /// Decoded once to a thumbnail, so a 3000 px scan costs a few hundred kB.
    public var cover: CGImage?
    public static let none = TrackTags()

    /// The cover is drawn 98 pt square; this covers a 3x screen.
    static let coverPixels = 320

    public static func read(url: URL) -> TrackTags {
        let tags = Tags.read(url: url)
        return TrackTags(artist: tags.artist, title: tags.title, cover: tags.picture.flatMap { thumbnail($0.data) })
    }

    /// A cover on disk for its row and MORE, which draws it 148 pt wide on a 2x screen.
    static func rowCoverJPEG(_ data: Data) -> Data? {
        guard let image = thumbnail(data, pixels: 296) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    static func thumbnail(_ data: Data, pixels: Int = coverPixels) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
