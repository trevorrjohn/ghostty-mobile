import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image ready to upload: a private temporary file with no location or camera metadata.
struct PreparedImage: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let fileExtension: String
    let byteCount: Int
}

enum ImageUploadPreparer {
    static let cameraLongSide = 2_048
    static let cameraJPEGQuality = 0.85
    static let photoJPEGQuality = 0.9

    /// Decodes `data`, applies its orientation, and re-encodes it without metadata (EXIF, GPS, camera and
    /// maker notes). Screenshots and other lossless sources stay PNG; photos become JPEG, which also converts HEIC.
    /// Camera photos are downscaled so the longest side is at most 2048 px.
    static func prepare(data: Data, source: ImageUploadSource, directory: URL = defaultDirectory) throws -> PreparedImage {
        guard data.count <= maximumImageUploadBytes * 4,
              let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(imageSource) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw ImageUploadError.unsupportedImage }

        let type = (CGImageSourceGetType(imageSource) as String?).flatMap(UTType.init)
        let lossless = type.map { $0.conforms(to: .png) || $0.conforms(to: .gif) || $0.conforms(to: .webP) } ?? false
        let outputType: UTType = lossless ? .png : .jpeg
        let longSide = max(width, height)
        let target = source == .camera ? min(longSide, cameraLongSide) : longSide

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: target,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions as CFDictionary) else {
            throw ImageUploadError.unsupportedImage
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, outputType.identifier as CFString, 1, nil) else {
            throw ImageUploadError.unsupportedImage
        }
        var destinationProperties: [CFString: Any] = [:]
        if outputType == .jpeg {
            destinationProperties[kCGImageDestinationLossyCompressionQuality] = source == .camera ? cameraJPEGQuality : photoJPEGQuality
        }
        // Only the pixels and compression quality are passed on: no EXIF, GPS, TIFF or maker-note dictionaries.
        CGImageDestinationAddImage(destination, image, destinationProperties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageUploadError.unsupportedImage }
        guard output.length <= maximumImageUploadBytes else { throw ImageUploadError.tooLarge }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        let fileExtension = outputType == .png ? "png" : "jpg"
        let url = directory.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
        try (output as Data).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return PreparedImage(id: UUID(), url: url, fileExtension: fileExtension, byteCount: output.length)
    }

    static func prepare(fileAt url: URL, source: ImageUploadSource, directory: URL = defaultDirectory) throws -> PreparedImage {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumImageUploadBytes * 4 else { throw ImageUploadError.tooLarge }
        return try prepare(data: try Data(contentsOf: url, options: .mappedIfSafe), source: source, directory: directory)
    }

    static var defaultDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ImageUpload", isDirectory: true)
    }

    static func discard(_ images: [PreparedImage]) {
        for image in images { try? FileManager.default.removeItem(at: image.url) }
    }
}
