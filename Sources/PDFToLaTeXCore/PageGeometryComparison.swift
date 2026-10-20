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
    /// classification.
    static func groups(_ sizes: [CGSize]) -> [PageSizeGroup] {
        var order: [CGSize] = []
        var members: [CGSize: [Int]] = [:]
        for (index, size) in sizes.enumerated() {
            if members[size] == nil { order.append(size) }
            members[size, default: []].append(index + 1)
        }
        return order.map { size in
            PageSizeGroup(width: Double(size.width), height: Double(size.height),
                          classification: PageGeometry.classify(size).rawValue, pages: members[size] ?? [])
        }
    }

    /// "W × H bp" for each group, with two decimals unless two groups of the
    /// list would then print alike, in which case those get four.
    static func labels(_ groups: [PageSizeGroup]) -> [String] {
        func label(_ group: PageSizeGroup, _ digits: Int) -> String {
            String(format: "%.\(digits)f × %.\(digits)f bp", group.width, group.height)
        }
        let short = groups.map { label($0, 2) }
        return groups.enumerated().map { index, group in
            short.filter { $0 == short[index] }.count > 1 ? label(group, 4) : short[index]
        }
    }

    /// Console section printed by PDFComparator.compare.
    func printReport() {
        for (label, groups) in [("Original", originalSizes), ("Reproduced", reproducedSizes)] {
            print("  \(label):")
            for (size, group) in zip(Self.labels(groups), groups) {
                print(String(format: "    %@  %@  %d page%@ (%@)", size, group.classification, group.pages.count,
                             group.pages.count == 1 ? "" : "s", Self.ranges(group.pages)))
            }
        }
        if mismatchedPages.isEmpty {
            print("  Page sizes match on every paired page")
        } else {
            print("  Pages whose size differs: \(Self.ranges(mismatchedPages))")
        }
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
