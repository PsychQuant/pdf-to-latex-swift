import Foundation
import PDFKit
import PDFVisualDiff

/// Pages of one document that share a size (rounded to 0.01 bp).
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
    /// sizes differ by more than 0.01 bp in either dimension.
    public let mismatchedPages: [Int]

    public static func compare(original: PDFDocument, reproduced: PDFDocument) -> PageGeometryComparison {
        let a = sizes(of: original), b = sizes(of: reproduced)
        var mismatched: [Int] = []
        for i in 0..<min(a.count, b.count)
        where abs(a[i].width - b[i].width) > 0.01 || abs(a[i].height - b[i].height) > 0.01 {
            mismatched.append(i + 1)
        }
        return PageGeometryComparison(originalSizes: groups(a), reproducedSizes: groups(b), mismatchedPages: mismatched)
    }

    static func sizes(of document: PDFDocument) -> [CGSize] {
        (0..<document.pageCount).map { document.page(at: $0)?.bounds(for: .cropBox).size ?? .zero }
    }

    static func groups(_ sizes: [CGSize]) -> [PageSizeGroup] {
        var order: [String] = []
        var members: [String: (CGSize, [Int])] = [:]
        for (index, size) in sizes.enumerated() {
            let key = String(format: "%.2f×%.2f", size.width, size.height)
            if members[key] == nil {
                order.append(key)
                members[key] = (size, [])
            }
            members[key]?.1.append(index + 1)
        }
        return order.compactMap { key in
            guard let (size, pages) = members[key] else { return nil }
            return PageSizeGroup(width: (Double(size.width) * 100).rounded() / 100,
                                 height: (Double(size.height) * 100).rounded() / 100,
                                 classification: PageGeometry.classify(size).rawValue,
                                 pages: pages)
        }
    }

    /// Console section printed by PDFComparator.compare.
    func printReport() {
        for (label, groups) in [("Original", originalSizes), ("Reproduced", reproducedSizes)] {
            print("  \(label):")
            for group in groups {
                print(String(format: "    %.2f × %.2f bp  %@  %d page%@ (%@)", group.width, group.height,
                             group.classification, group.pages.count, group.pages.count == 1 ? "" : "s",
                             Self.ranges(group.pages)))
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
