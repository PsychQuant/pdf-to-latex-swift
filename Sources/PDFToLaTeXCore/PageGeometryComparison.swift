import CoreGraphics
import Foundation
import PDFKit
import PDFVisualDiff

/// Pages of one document that share a size exactly, as displayed (after the
/// page's /Rotate).
public struct PageSizeGroup: Codable, Equatable, Sendable {
    public let width: Double
    public let height: Double
    /// `exactA4`, `nearA4` or `other`, as classified by PDFVisualDiff.PageGeometry.
    public let classification: String
    /// 1-based page numbers.
    public let pages: [Int]
}

/// Page-geometry layer of the PDF comparison: the page sizes of both
/// documents, how each size relates to A4 (210 × 297 mm), and which paired
/// pages differ in size.
public struct PageGeometryComparison: Codable, Equatable, Sendable {
    public let originalSizes: [PageSizeGroup]
    public let reproducedSizes: [PageSizeGroup]
    /// 1-based page numbers, among pages present in both documents, whose
    /// displayed sizes are not identical. No tolerance is applied: the same
    /// box numbers in two files give the same values.
    public let mismatchedPages: [Int]

    public static func compare(original: PDFDocument, reproduced: PDFDocument) -> PageGeometryComparison {
        let a = sizes(of: original), b = sizes(of: reproduced)
        let mismatched = (0..<min(a.count, b.count)).filter { a[$0] != b[$0] }.map { $0 + 1 }
        return PageGeometryComparison(originalSizes: groups(a), reproducedSizes: groups(b), mismatchedPages: mismatched)
    }

    /// Crop-box sizes as a viewer shows them: width and height swap on pages
    /// rotated by 90° or 270°.
    static func sizes(of document: PDFDocument) -> [CGSize] {
        (0..<document.pageCount).map { index in
            guard let page = document.page(at: index) else { return .zero }
            let size = page.bounds(for: .cropBox).size
            return (page.rotation % 180 + 180) % 180 == 90 ? CGSize(width: size.height, height: size.width) : size
        }
    }

    /// Groups pages by exact size, so every page of a group has the same
    /// classification. A size is classified regardless of orientation, so a
    /// landscape A4 page is A4.
    static func groups(_ sizes: [CGSize]) -> [PageSizeGroup] {
        var order: [CGSize] = []
        var members: [CGSize: [Int]] = [:]
        for (index, size) in sizes.enumerated() {
            if members[size] == nil { order.append(size) }
            members[size, default: []].append(index + 1)
        }
        return order.map { size in
            let portrait = CGSize(width: min(size.width, size.height), height: max(size.width, size.height))
            return PageSizeGroup(width: Double(size.width), height: Double(size.height),
                                 classification: PageGeometry.classify(portrait).rawValue, pages: members[size] ?? [])
        }
    }

    /// The fewest decimals (2, 4, …, 16) at which every distinct size in
    /// `sizes` prints differently, so two different sizes never look alike;
    /// 16 decimals tell apart any two page sizes a PDF can hold.
    static func decimals(for sizes: [CGSize]) -> Int {
        let distinct = Set(sizes)
        for digits in stride(from: 2, through: 16, by: 2) where Set(distinct.map { label($0, digits) }).count == distinct.count {
            return digits
        }
        return 16
    }

    static func label(_ size: CGSize, _ digits: Int) -> String {
        String(format: "%.\(digits)f × %.\(digits)f bp", size.width, size.height)
    }

    /// "OK", or "MISMATCH (pages …)" listing the paired pages whose sizes differ.
    public var verdict: String {
        mismatchedPages.isEmpty ? "OK" : "MISMATCH (pages \(Self.ranges(mismatchedPages)))"
    }

    /// Pages listed with both sizes after "Pages whose size differs".
    static let detailLimit = 10

    /// The console section, one string per line; sizes of both documents
    /// share one precision, so equal labels always mean equal sizes.
    func reportLines() -> [String] {
        func size(_ group: PageSizeGroup) -> CGSize { CGSize(width: group.width, height: group.height) }
        func sizeOf(page: Int, in groups: [PageSizeGroup]) -> CGSize? {
            groups.first { $0.pages.contains(page) }.map(size)
        }
        let digits = Self.decimals(for: (originalSizes + reproducedSizes).map(size))
        var lines: [String] = []
        for (label, groups) in [("Original", originalSizes), ("Reproduced", reproducedSizes)] {
            lines.append("  \(label):")
            for group in groups {
                lines.append(String(format: "    %@  %@  %d page%@ (%@)", Self.label(size(group), digits),
                                    group.classification, group.pages.count, group.pages.count == 1 ? "" : "s",
                                    Self.ranges(group.pages)))
            }
        }
        if mismatchedPages.isEmpty {
            lines.append("  Page sizes match on every paired page")
        } else {
            lines.append("  Pages whose size differs: \(Self.ranges(mismatchedPages))")
            for page in mismatchedPages.prefix(Self.detailLimit) {
                guard let a = sizeOf(page: page, in: originalSizes), let b = sizeOf(page: page, in: reproducedSizes) else { continue }
                lines.append("    page \(page): \(Self.label(a, digits)) → \(Self.label(b, digits))")
            }
            if mismatchedPages.count > Self.detailLimit {
                lines.append("    … \(mismatchedPages.count - Self.detailLimit) more")
            }
        }
        return lines
    }

    /// Console section printed by PDFComparator.compare.
    func printReport() {
        reportLines().forEach { print($0) }
    }

    /// "1-4, 7, 9-10"
    static func ranges(_ pages: [Int]) -> String {
        var parts: [String] = []
        var start: Int?
        var previous: Int?
        for page in pages + [Int.min] {
            if let p = previous, page == p + 1 { previous = page; continue }
            if let s = start, let p = previous { parts.append(s == p ? "\(s)" : "\(s)-\(p)") }
            start = page
            previous = page
        }
        return parts.joined(separator: ", ")
    }
}
