import Foundation

public struct ProjectManifest: Codable, Sendable {
    public var schemaVersion: Int
    public var createdAt: String
    public var updatedAt: String
    public var projectName: String
    public var sourcePDF: String
    public var projectRoot: String
    public var pages: [PageRecord]
    public var blocks: [BlockRecord]
    public var ocrResults: [PageOCRResult]

    public init(
        schemaVersion: Int, createdAt: String, updatedAt: String,
        projectName: String, sourcePDF: String, projectRoot: String,
        pages: [PageRecord], blocks: [BlockRecord],
        ocrResults: [PageOCRResult] = []
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.projectName = projectName
        self.sourcePDF = sourcePDF
        self.projectRoot = projectRoot
        self.pages = pages
        self.blocks = blocks
        self.ocrResults = ocrResults
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, createdAt, updatedAt, projectName
        case sourcePDF, projectRoot, pages, blocks, ocrResults
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        projectName = try container.decode(String.self, forKey: .projectName)
        sourcePDF = try container.decode(String.self, forKey: .sourcePDF)
        projectRoot = try container.decode(String.self, forKey: .projectRoot)
        pages = try container.decode([PageRecord].self, forKey: .pages)
        blocks = try container.decode([BlockRecord].self, forKey: .blocks)
        ocrResults = try container.decodeIfPresent([PageOCRResult].self, forKey: .ocrResults) ?? []
    }
}

public struct PageRecord: Codable, Sendable {
    public var number: Int
    public var width: Double
    public var height: Double
    public var rotation: Int
    public var renderedImagePath: String?
    public var renderedDPI: Double?
    /// PDF 的 page label（`/PageLabels`，例如 `iv`、`12`、`A-3`），原樣記錄（PsychQuant/macdoc#211）。
    /// 只有 PDF 真的有 `/PageLabels` 時才有值；舊 manifest 沒有這個欄位，解碼為 nil。
    public var label: String?

    public init(
        number: Int, width: Double, height: Double, rotation: Int,
        renderedImagePath: String?, renderedDPI: Double?, label: String? = nil
    ) {
        self.number = number
        self.width = width
        self.height = height
        self.rotation = rotation
        self.renderedImagePath = renderedImagePath
        self.renderedDPI = renderedDPI
        self.label = label
    }
}

public struct BlockRecord: Codable, Sendable {
    public var id: String
    public var page: Int
    public var type: BlockType
    public var status: BlockStatus
    public var bbox: BoundingBox
    public var imagePath: String?
    public var latexPath: String?
    public var textPreview: String?
    public var notes: String?
    public var attemptCount: Int?
    public var lastAttemptAt: String?
    public var completedAt: String?
    public var lastModel: String?
    public var lastReasoningEffort: String?
    public var lastTimeoutSeconds: Double?

    public init(
        id: String, page: Int, type: BlockType, status: BlockStatus,
        bbox: BoundingBox, imagePath: String? = nil, latexPath: String? = nil,
        textPreview: String? = nil, notes: String? = nil,
        attemptCount: Int? = nil, lastAttemptAt: String? = nil,
        completedAt: String? = nil, lastModel: String? = nil,
        lastReasoningEffort: String? = nil, lastTimeoutSeconds: Double? = nil
    ) {
        self.id = id
        self.page = page
        self.type = type
        self.status = status
        self.bbox = bbox
        self.imagePath = imagePath
        self.latexPath = latexPath
        self.textPreview = textPreview
        self.notes = notes
        self.attemptCount = attemptCount
        self.lastAttemptAt = lastAttemptAt
        self.completedAt = completedAt
        self.lastModel = lastModel
        self.lastReasoningEffort = lastReasoningEffort
        self.lastTimeoutSeconds = lastTimeoutSeconds
    }
}

public struct BoundingBox: Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum BlockType: String, Codable, CaseIterable, Sendable {
    case text
    case equation
    case table
    case figure
    case caption
    case footnote
    case theorem
    case proof
    case unknown
}

public enum BlockStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case segmented
    case queued
    case transcribing
    case transcribed
    case verified
    case fallbackImage = "fallback_image"
    case failed

    public var isRunnableWithoutOverwrite: Bool {
        switch self {
        case .segmented, .queued, .failed:
            return true
        default:
            return false
        }
    }

    public var countsAsSuccess: Bool {
        self == .transcribed || self == .fallbackImage
    }
}

public struct PDFPageSnapshot: Sendable {
    public var number: Int
    public var width: Double
    public var height: Double
    public var rotation: Int
    /// PDF 的 page label；PDF 沒有 `/PageLabels` 時為 nil（見 `PDFScanner.scan`）。
    public var label: String?

    public init(number: Int, width: Double, height: Double, rotation: Int, label: String? = nil) {
        self.number = number
        self.width = width
        self.height = height
        self.rotation = rotation
        self.label = label
    }
}

public struct DetectedBlock: Sendable {
    public var bbox: BoundingBox
    public var type: BlockType
    public var textPreview: String?

    public init(bbox: BoundingBox, type: BlockType, textPreview: String?) {
        self.bbox = bbox
        self.type = type
        self.textPreview = textPreview
    }
}

public struct RenderedPage: Sendable {
    public var pageNumber: Int
    public var imagePath: String

    public init(pageNumber: Int, imagePath: String) {
        self.pageNumber = pageNumber
        self.imagePath = imagePath
    }
}

public struct ResolvedProject: Sendable {
    public var root: URL
    public var manifestURL: URL
    public var manifest: ProjectManifest
    public var pdfURL: URL

    public init(root: URL, manifestURL: URL, manifest: ProjectManifest, pdfURL: URL) {
        self.root = root
        self.manifestURL = manifestURL
        self.manifest = manifest
        self.pdfURL = pdfURL
    }
}

public struct TranscriptionOutcome: Sendable {
    public var blockID: String
    public var status: BlockStatus
    public var snippetPath: String?
    public var notes: String?

    public init(blockID: String, status: BlockStatus, snippetPath: String?, notes: String?) {
        self.blockID = blockID
        self.status = status
        self.snippetPath = snippetPath
        self.notes = notes
    }
}

public struct TranscriptionResult: Codable, Sendable {
    public var latex: String
    public var confidence: Double?
    public var needsFallback: Bool
    public var notes: String?

    public init(latex: String, confidence: Double?, needsFallback: Bool, notes: String?) {
        self.latex = latex
        self.confidence = confidence
        self.needsFallback = needsFallback
        self.notes = notes
    }
}

/// Codex CLI reasoning effort 設定。
public enum ReasoningEffort: String, CaseIterable, Sendable {
    case none
    case low
    case medium
    case high
    case xhigh
}

/// AI CLI 後端選擇。可透過 `--backend` 明確指定，或從 `--model` 名稱自動偵測。
public enum TranscriptionBackend: String, CaseIterable, Sendable {
    case codex
    case claude
    case gemini

    /// 從模型名稱自動偵測後端。
    public static func detect(from model: String) -> TranscriptionBackend {
        let lower = model.lowercased()
        if lower.hasPrefix("claude") { return .claude }
        if lower.hasPrefix("gemini") { return .gemini }
        return .codex
    }

    /// 各 backend 預設模型（通用模型，非 coding 專用）。
    public var defaultModel: String {
        switch self {
        case .codex: return "gpt-5.4"
        case .claude: return "claude-sonnet-4-6"
        case .gemini: return "gemini-3.1-pro-preview"
        }
    }

    /// 預設每次送幾頁。統一 2 頁以確保品質。
    public var defaultPagesPerRequest: Int { 2 }
}

public struct ChapterSpec: Codable, Sendable {
    public var id: String
    public var title: String
    public var startPage: Int
    public var endPage: Int

    public var pageNumbers: [Int] {
        Array(startPage...endPage)
    }

    public init(id: String, title: String, startPage: Int, endPage: Int) {
        self.id = id
        self.title = title
        self.startPage = startPage
        self.endPage = endPage
    }
}

public struct ChapterConfigFile: Codable, Sendable {
    public var strategy: String?
    public var generatedAt: String?
    public var sourcePDF: String?
    public var chapters: [ChapterSpec]

    public init(strategy: String?, generatedAt: String?, sourcePDF: String?, chapters: [ChapterSpec]) {
        self.strategy = strategy
        self.generatedAt = generatedAt
        self.sourcePDF = sourcePDF
        self.chapters = chapters
    }
}

public struct AssembledDocument: Sendable {
    public var root: URL
    public var mainTexURL: URL
    public var chapterTexURLs: [URL]
    public var pageTexURLs: [URL]

    public init(root: URL, mainTexURL: URL, chapterTexURLs: [URL], pageTexURLs: [URL]) {
        self.root = root
        self.mainTexURL = mainTexURL
        self.chapterTexURLs = chapterTexURLs
        self.pageTexURLs = pageTexURLs
    }
}

// MARK: - Page-level Transcription

/// 單頁轉寫結果（page-level pipeline 用）。
public struct PageResult: Codable, Sendable {
    public var page: Int
    public var latex: String
    public var figures: [FigureRegion]
    public var confidence: Double?
    public var notes: String?
    /// 具體不確定區域。未來 AI 可只看此欄位即可定位並修正問題。
    public var uncertainties: [UncertainArea]?

    public init(
        page: Int, latex: String, figures: [FigureRegion],
        confidence: Double?, notes: String?, uncertainties: [UncertainArea]? = nil
    ) {
        self.page = page
        self.latex = latex
        self.figures = figures
        self.confidence = confidence
        self.notes = notes
        self.uncertainties = uncertainties
    }
}

/// 轉寫中的一個不確定區域。記錄足夠資訊讓後續 AI 能精準修正。
public struct UncertainArea: Codable, Sendable {
    /// 不確定的 LaTeX 片段（原文擷取）。
    public var snippet: String
    /// 不確定的原因分類。
    public var reason: UncertaintyReason
    /// 人類可讀的描述，說明為何不確定。
    public var description: String
    /// 可能的替代寫法（若有）。
    public var alternatives: [String]?

    public init(snippet: String, reason: UncertaintyReason, description: String, alternatives: [String]? = nil) {
        self.snippet = snippet
        self.reason = reason
        self.description = description
        self.alternatives = alternatives
    }
}

/// 不確定原因的列舉。
public enum UncertaintyReason: String, Codable, Sendable {
    /// 符號模糊（如 l vs 1 vs |，α vs a 等）
    case ambiguousSymbol = "ambiguous_symbol"
    /// 佈局不確定（行間距、對齊、分欄等）
    case layoutUnclear = "layout_unclear"
    /// 部分被遮擋或模糊
    case occludedOrBlurry = "occluded_or_blurry"
    /// 手寫或非標準字體
    case handwrittenOrUnusualFont = "handwritten_or_unusual_font"
    /// 數學結構複雜（多層嵌套、矩陣等）
    case complexMathStructure = "complex_math_structure"
    /// 表格結構不確定
    case tableStructure = "table_structure"
    /// 其他
    case other
}

/// 頁面中需裁切的 figure 區域。bbox 為正規化座標 [x, y, width, height]，範圍 0-1。
public struct FigureRegion: Codable, Sendable {
    public var id: String
    public var bbox: [Double]
    public var caption: String?

    public init(id: String, bbox: [Double], caption: String?) {
        self.id = id
        self.bbox = bbox
        self.caption = caption
    }
}

/// 一次 page-level 請求的完整回應。
public struct PageTranscriptionResponse: Codable, Sendable {
    public var pages: [PageResult]

    public init(pages: [PageResult]) {
        self.pages = pages
    }
}

// MARK: - Page-level OCR (Simplified Pipeline)

/// 單頁 OCR 結果（簡化 pipeline 用）。
public struct PageOCRResult: Codable, Sendable {
    public var pageNumber: Int
    public var ocrText: String
    public var pdfkitText: String?
    public var ocrTextPath: String?
    public var agreement: Double?
    public var hasConflicts: Bool

    public init(
        pageNumber: Int, ocrText: String, pdfkitText: String? = nil,
        ocrTextPath: String? = nil, agreement: Double? = nil,
        hasConflicts: Bool = false
    ) {
        self.pageNumber = pageNumber
        self.ocrText = ocrText
        self.pdfkitText = pdfkitText
        self.ocrTextPath = ocrTextPath
        self.agreement = agreement
        self.hasConflicts = hasConflicts
    }
}

public enum ChapterStrategy: String, CaseIterable, Sendable {
    case auto
    case outline
    case toc
    case headings
    case pages
    case single
    case custom
}
