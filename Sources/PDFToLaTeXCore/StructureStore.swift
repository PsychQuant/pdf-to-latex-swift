import Foundation

/// 管理 Phase 0 結構掃描結果的持久化。
/// - `structure.json`: document-level 資訊（pdfType, pageOffset, chapters, totalPages）
/// - `layouts/page-NNN.json`: 每頁的 layout 分析結果
public struct StructureStore: Sendable {
    private let projectRoot: URL
    private nonisolated(unsafe) let fm = FileManager.default

    public init(projectRoot: URL) {
        self.projectRoot = projectRoot
    }

    // MARK: - Paths

    private var structureURL: URL {
        projectRoot.appendingPathComponent("structure.json")
    }

    private var layoutsDir: URL {
        projectRoot.appendingPathComponent("layouts", isDirectory: true)
    }

    private func layoutURL(for pageNumber: Int) -> URL {
        layoutsDir.appendingPathComponent(String(format: "page-%03d.json", pageNumber))
    }

    // MARK: - Document-level Structure

    /// 儲存 document-level 結構（不含 per-page layouts）。
    public func saveStructure(_ structure: PDFStructureScanner.DocumentStructure) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(structure)
        try data.write(to: structureURL, options: .atomic)
    }

    /// 載入 document-level 結構。
    public func loadStructure() throws -> PDFStructureScanner.DocumentStructure? {
        guard fm.fileExists(atPath: structureURL.path) else { return nil }
        let data = try Data(contentsOf: structureURL)
        return try JSONDecoder().decode(PDFStructureScanner.DocumentStructure.self, from: data)
    }

    /// 是否已有結構掃描結果。
    public var hasStructure: Bool {
        fm.fileExists(atPath: structureURL.path)
    }

    // MARK: - Per-page Layout

    /// 儲存單頁 layout。
    public func savePageLayout(_ layout: PDFStructureScanner.PageLayout) throws {
        try fm.createDirectory(at: layoutsDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(layout)
        try data.write(to: layoutURL(for: layout.pageNumber), options: .atomic)
    }

    /// 批次儲存多頁 layout。
    public func savePageLayouts(_ layouts: [PDFStructureScanner.PageLayout]) throws {
        try fm.createDirectory(at: layoutsDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for layout in layouts {
            let data = try encoder.encode(layout)
            try data.write(to: layoutURL(for: layout.pageNumber), options: .atomic)
        }
    }

    /// 載入單頁 layout。
    public func loadPageLayout(pageNumber: Int) -> PDFStructureScanner.PageLayout? {
        let url = layoutURL(for: pageNumber)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PDFStructureScanner.PageLayout.self, from: data)
    }

    /// 批次載入多頁 layout（只載入存在的）。
    public func loadPageLayouts(pageNumbers: [Int]) -> [PDFStructureScanner.PageLayout] {
        pageNumbers.compactMap { loadPageLayout(pageNumber: $0) }
    }

    /// 檢查某頁是否已有 layout cache。
    public func hasPageLayout(pageNumber: Int) -> Bool {
        fm.fileExists(atPath: layoutURL(for: pageNumber).path)
    }

    /// 回傳尚未掃描的頁碼。
    public func pendingPages(from pageNumbers: [Int]) -> [Int] {
        pageNumbers.filter { !hasPageLayout(pageNumber: $0) }
    }

    /// 已掃描的頁數。
    public var scannedPageCount: Int {
        let contents = (try? fm.contentsOfDirectory(atPath: layoutsDir.path)) ?? []
        return contents.filter { $0.hasSuffix(".json") }.count
    }

    // MARK: - Scan + Save (convenience)

    /// 更新 structure.json 中的 sourceDetection 欄位。
    public func saveSourceDetection(_ detection: PDFSourceDetection) throws {
        guard var structure = try loadStructure() else {
            throw NSError(domain: "StructureStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "structure.json not found"])
        }
        structure.sourceDetection = detection
        try saveStructure(structure)
    }

    /// 掃描整本 PDF 並持久化所有結果。已掃描的頁面會跳過。
    /// 同時自動偵測 PDF 來源格式並存入 structure.json。
    public func scanAndSave(pdfURL: URL) throws -> PDFStructureScanner.DocumentStructure {
        let scanner = PDFStructureScanner()
        var structure = try scanner.scan(pdfURL: pdfURL)

        // 自動偵測來源格式
        let detector = PDFSourceDetector()
        structure.sourceDetection = detector.detect(from: pdfURL)

        // 存 document-level
        try saveStructure(structure)

        // 存 per-page layouts（跳過已存在的）
        try fm.createDirectory(at: layoutsDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for layout in structure.pageLayouts {
            let url = layoutURL(for: layout.pageNumber)
            if !fm.fileExists(atPath: url.path) {
                let data = try encoder.encode(layout)
                try data.write(to: url, options: .atomic)
            }
        }

        return structure
    }
}
