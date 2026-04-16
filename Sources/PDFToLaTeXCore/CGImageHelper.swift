import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum CGImageHelper {
    public static func load(from url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw PDFToLaTeXError.imageCannotOpen(url)
        }

        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PDFToLaTeXError.imageCannotDecode(url)
        }

        return image
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw PDFToLaTeXError.imageCannotCreateDestination(url)
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PDFToLaTeXError.imageFinalizeFailed(url)
        }
    }
}
