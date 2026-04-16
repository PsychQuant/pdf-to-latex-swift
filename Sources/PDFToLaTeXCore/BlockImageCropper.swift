import CoreGraphics
import Foundation

public struct BlockImageCropper: Sendable {
    public init() {}

    public func crop(
        pageImageURL: URL,
        pageWidth: Double,
        pageHeight: Double,
        bbox: BoundingBox,
        outputURL: URL
    ) throws {
        guard bbox.width > 0, bbox.height > 0 else {
            throw PDFToLaTeXError.invalidCrop(bbox)
        }

        let pageImage = try CGImageHelper.load(from: pageImageURL)
        let scaleX = Double(pageImage.width) / pageWidth
        let scaleY = Double(pageImage.height) / pageHeight

        var rect = CGRect(
            x: floor(bbox.x * scaleX),
            y: floor((pageHeight - bbox.y - bbox.height) * scaleY),
            width: ceil(bbox.width * scaleX),
            height: ceil(bbox.height * scaleY)
        )
        rect = rect.intersection(CGRect(x: 0, y: 0, width: pageImage.width, height: pageImage.height))

        guard !rect.isNull, rect.width > 0, rect.height > 0, let cropped = pageImage.cropping(to: rect) else {
            throw PDFToLaTeXError.cropFailed(pageImageURL)
        }
        try CGImageHelper.writePNG(cropped, to: outputURL)
    }
}
