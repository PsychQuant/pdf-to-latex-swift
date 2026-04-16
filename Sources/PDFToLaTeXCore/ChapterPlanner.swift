import Foundation
import PDFKit

public struct ChapterPlanner: Sendable {
    public init() {}

    public func plan(
        strategy: ChapterStrategy,
        project: ResolvedProject,
        pageNumbers: [Int],
        pageRanges: String?,
        chapterConfig: URL?
    ) throws -> [ChapterSpec] {
        switch strategy {
        case .single:
            return [singleChapter(for: pageNumbers)]
        case .pages:
            guard let pageRanges else { throw PDFToLaTeXError.missingPageRanges }
            return try plansFromPageRanges(pageRanges, allowedPages: pageNumbers)
        case .custom:
            guard let chapterConfig else { throw PDFToLaTeXError.missingChapterConfig }
            return try plansFromCustomConfig(chapterConfig, allowedPages: pageNumbers)
        case .outline:
            return outlinePlans(project: project, allowedPages: pageNumbers)
        case .toc:
            return tocPlans(project: project, allowedPages: pageNumbers)
        case .headings:
            return headingPlans(project: project, allowedPages: pageNumbers)
        case .auto:
            let outline = outlinePlans(project: project, allowedPages: pageNumbers)
            if !outline.isEmpty { return outline }
            let toc = tocPlans(project: project, allowedPages: pageNumbers)
            if !toc.isEmpty { return toc }
            let headings = headingPlans(project: project, allowedPages: pageNumbers)
            if !headings.isEmpty { return headings }
            if let pageRanges {
                return try plansFromPageRanges(pageRanges, allowedPages: pageNumbers)
            }
            return [singleChapter(for: pageNumbers)]
        }
    }

    private func singleChapter(for pageNumbers: [Int]) -> ChapterSpec {
        ChapterSpec(
            id: "chapter-all",
            title: "Document",
            startPage: pageNumbers.first ?? 1,
            endPage: pageNumbers.last ?? 1
        )
    }

    private func plansFromPageRanges(_ pageRanges: String, allowedPages: [Int]) throws -> [ChapterSpec] {
        let allowedSet = Set(allowedPages)
        let tokens = pageRanges
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var specs: [ChapterSpec] = []
        for (index, token) in tokens.enumerated() {
            let parts = token.split(separator: "-", maxSplits: 1).map(String.init)
            guard let start = Int(parts[0]) else {
                throw PDFToLaTeXError.invalidRangeToken(token)
            }
            let end: Int
            if parts.count == 2 {
                guard let parsedEnd = Int(parts[1]) else {
                    throw PDFToLaTeXError.invalidRangeToken(token)
                }
                end = parsedEnd
            } else {
                end = start
            }
            guard start <= end else {
                throw PDFToLaTeXError.invalidRange(start, end)
            }
            guard allowedSet.contains(start), allowedSet.contains(end) else {
                throw PDFToLaTeXError.invalidRangeToken(token)
            }
            specs.append(
                ChapterSpec(
                    id: String(format: "chapter-%02d", index + 1),
                    title: "Pages \(start)-\(end)",
                    startPage: start,
                    endPage: end
                )
            )
        }

        return specs
    }

    private func plansFromCustomConfig(_ url: URL, allowedPages: [Int]) throws -> [ChapterSpec] {
        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(ChapterConfigFile.self, from: data)
        let allowedSet = Set(allowedPages)

        for chapter in config.chapters {
            if chapter.startPage > chapter.endPage {
                throw PDFToLaTeXError.invalidCustomConfig("chapter \(chapter.id) 頁碼範圍反向")
            }
            if !allowedSet.contains(chapter.startPage) || !allowedSet.contains(chapter.endPage) {
                throw PDFToLaTeXError.invalidCustomConfig("chapter \(chapter.id) 超出目前頁碼範圍")
            }
        }

        return config.chapters
    }

    private func tocPlans(project: ResolvedProject, allowedPages: [Int]) -> [ChapterSpec] {
        let scanner = PDFStructureScanner()
        guard let structure = try? scanner.scan(pdfURL: project.pdfURL) else { return [] }
        let rawChapters = structure.chapters
        guard !rawChapters.isEmpty else { return [] }

        let allowedSet = Set(allowedPages)
        let minPage = allowedPages.first ?? 1
        let maxPage = allowedPages.last ?? rawChapters.last!.endPage

        var result: [ChapterSpec] = []
        for spec in rawChapters {
            guard allowedSet.contains(spec.startPage) || allowedSet.contains(spec.endPage) else {
                continue
            }
            let start = max(spec.startPage, minPage)
            let end = min(spec.endPage, maxPage)
            guard start <= end else { continue }
            result.append(ChapterSpec(id: spec.id, title: spec.title, startPage: start, endPage: end))
        }
        return result
    }

    private func outlinePlans(project: ResolvedProject, allowedPages: [Int]) -> [ChapterSpec] {
        guard let document = PDFDocument(url: project.pdfURL), let root = document.outlineRoot else {
            return []
        }

        let allowedSet = Set(allowedPages)
        let raw = flattenOutlines(root: root, document: document)
            .filter { allowedSet.contains($0.page) }
            .sorted { $0.page < $1.page }

        guard !raw.isEmpty else { return [] }

        var specs: [ChapterSpec] = []
        for (index, item) in raw.enumerated() {
            let start = item.page
            let end = (index + 1 < raw.count) ? max(start, raw[index + 1].page - 1) : (allowedPages.last ?? start)
            if end < start { continue }
            specs.append(
                ChapterSpec(
                    id: slugified(item.label, fallback: String(format: "outline-%02d", index + 1)),
                    title: item.label,
                    startPage: start,
                    endPage: end
                )
            )
        }

        return normalized(specs, allowedPages: allowedPages)
    }

    private func headingPlans(project: ResolvedProject, allowedPages: [Int]) -> [ChapterSpec] {
        let allowedSet = Set(allowedPages)
        let candidates = project.manifest.blocks
            .filter { allowedSet.contains($0.page) }
            .compactMap { block -> (page: Int, title: String)? in
                guard block.type == .text || block.type == .theorem else { return nil }
                guard let preview = block.textPreview?.trimmingCharacters(in: .whitespacesAndNewlines), !preview.isEmpty else {
                    return nil
                }

                let firstLine = preview
                    .split(separator: "\n")
                    .map(String.init)
                    .first?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? preview

                let lower = firstLine.lowercased()
                let looksLikeChapter = lower.hasPrefix("chapter ")
                    || lower.hasPrefix("appendix ")
                    || firstLine.range(of: #"^\d+(\.\d+)?\s+[A-Z]"#, options: .regularExpression) != nil

                let likelyTitle = block.bbox.y + block.bbox.height > (project.manifest.pages[block.page - 1].height * 0.72)
                    && block.bbox.height >= 18
                    && firstLine.count <= 80

                guard looksLikeChapter || likelyTitle else { return nil }
                return (block.page, firstLine)
            }

        let deduped = Dictionary(grouping: candidates, by: \.page).compactMap { page, items in
            items.first.map { (page: page, title: $0.title) }
        }.sorted { $0.page < $1.page }

        guard !deduped.isEmpty else { return [] }

        let specs = deduped.enumerated().map { index, item in
            let end = (index + 1 < deduped.count) ? max(item.page, deduped[index + 1].page - 1) : (allowedPages.last ?? item.page)
            return ChapterSpec(
                id: slugified(item.title, fallback: String(format: "heading-%02d", index + 1)),
                title: item.title,
                startPage: item.page,
                endPage: end
            )
        }

        return normalized(specs, allowedPages: allowedPages)
    }

    private func flattenOutlines(root: PDFOutline, document: PDFDocument) -> [(label: String, page: Int)] {
        var result: [(label: String, page: Int)] = []

        func visit(_ outline: PDFOutline) {
            let label = outline.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !label.isEmpty, let destination = outline.destination, let page = destination.page {
                let pageIndex = document.index(for: page) + 1
                if pageIndex > 0 {
                    result.append((label, pageIndex))
                }
            }
            for childIndex in 0..<outline.numberOfChildren {
                if let child = outline.child(at: childIndex) {
                    visit(child)
                }
            }
        }

        visit(root)
        return result
    }

    private func normalized(_ specs: [ChapterSpec], allowedPages: [Int]) -> [ChapterSpec] {
        let minPage = allowedPages.first ?? 1
        let maxPage = allowedPages.last ?? minPage

        return specs.compactMap { spec in
            let start = max(spec.startPage, minPage)
            let end = min(spec.endPage, maxPage)
            guard start <= end else { return nil }
            return ChapterSpec(
                id: spec.id,
                title: spec.title,
                startPage: start,
                endPage: end
            )
        }
        .sorted { $0.startPage < $1.startPage }
    }

    private func slugified(_ text: String, fallback: String) -> String {
        let slug = text.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? fallback : slug
    }
}
