# pdf-to-latex-swift

原生 macOS 套件，將 PDF 轉換為可編譯的 LaTeX 文件。

## NAME

**pdf-to-latex** — convert PDF documents to compilable LaTeX source

## SYNOPSIS

```
macdoc pdf <command> [options]
```

Phase 1 (transcription):
```
macdoc pdf init       --pdf <file>
macdoc pdf segment    --project <dir>
macdoc pdf render     --project <dir>
macdoc pdf blocks     --project <dir>
macdoc pdf transcribe --project <dir> [--model <model>] [--backend <backend>]
macdoc pdf resume     --project <dir>
macdoc pdf chapters   --project <dir>
macdoc pdf assemble   --project <dir>
```

Phase 2 (consolidation):
```
macdoc pdf normalize      --project <dir>
macdoc pdf fix-envs       --project <dir> [--fix]
macdoc pdf compile-check  --project <dir>
macdoc pdf consolidate    --project <dir> [--dry-run] [--agent <agent>]
```

Utilities:
```
macdoc pdf detect-source  <file> [--json]
macdoc pdf compare        --original <file> --reproduced <file>
macdoc pdf status         --project <dir>
```

## DESCRIPTION

**pdf-to-latex** is a two-phase pipeline that converts PDF documents —
especially mathematical textbooks — into compilable LaTeX source files.

**Phase 1** extracts content from PDF pages using a combination of native
macOS frameworks (PDFKit, Vision, CoreGraphics) and external AI CLI tools:

```
PDF → pages(PNG) → blocks(Vision OCR) → transcribe(AI) → assemble(.tex)
```

**Phase 2** cleans and consolidates the raw LaTeX output into a single
compilable document:

```
accumulated.tex → normalize → fix-envs → compile-check → consolidate
```

The pipeline delegates AI transcription to external CLI tools (codex,
claude, gemini) rather than calling LLM APIs directly. This keeps
authentication, billing, and model selection outside the tool itself.

## SOURCE DETECTION

Before transcription, the pipeline can detect the PDF's original source
format. This changes the conversion strategy:

```
macdoc pdf detect-source textbook.pdf
```

Output:
```
detect-source: textbook.pdf
─────────────────────────────────────
  Format:     latex
  Engine:     pdfTeX
  Confidence: 90%
  Creator:    TeX
  Producer:   pdfTeX-1.40.21

  Evidence:
    - Creator: "TeX"
    - Metadata indicates pdfTeX
    - LaTeX fonts detected: Dcr10, Cmsy10, Cmmi10 (99% of total)
    - Text layer present (5/5 pages)
```

Detection uses two signal layers:

| Signal | Method | Reliability |
|--------|--------|-------------|
| Metadata | `/Creator`, `/Producer` fields | High (when present) |
| Fonts | BaseFont names from page resources | High for LaTeX (CM/DC/LM/SF) |
| Text layer | Character count per page | Detects scanned PDFs |

Detected formats and their pipeline implications:

| Source | Fonts | Strategy |
|--------|-------|----------|
| **latex** | Computer Modern, Latin Modern, DC/EC | Reconstruct LaTeX environments (theorem, proof, etc.) |
| **word** | Calibri, Cambria, Times New Roman | Extract content, use basic LaTeX formatting |
| **typst** | (metadata-based) | Similar to LaTeX, different syntax conventions |
| **scanned** | (no fonts / no text layer) | OCR first, lower quality expectations |
| **designer** | (InDesign, Quark) | Layout-oriented, structure may be irregular |

Use `--source <format>` on `transcribe` to override auto-detection.

## AI BACKENDS

Transcription delegates to external CLI tools. The backend is auto-detected
from the `--model` name, or explicitly set with `--backend`:

| CLI | Auto-detect prefix | Install |
|-----|-------------------|---------|
| `codex` | gpt, o1, o3 | `npm i -g @openai/codex` |
| `claude` | claude | `npm i -g @anthropic-ai/claude-code` |
| `gemini` | gemini | Google Gemini CLI |

```bash
macdoc pdf transcribe --project ./book --model gpt-5.4
macdoc pdf transcribe --project ./book --model claude-sonnet-4-6
macdoc pdf transcribe --project ./book --model my-model --backend codex
```

Why CLI, not API:
1. Authentication handled by the CLI tool, not macdoc
2. Model switching costs nothing — change `--model`
3. Offline-friendly — only `transcribe` needs network

## STATE MANAGEMENT

Each project tracks state in `manifest.json`. Block states:

```
pending → segmented → queued → transcribing → transcribed
                                    ↓                ↓
                                  failed        fallbackImage
```

Interrupted runs resume automatically — blocks in `transcribing` state
revert to `queued` on restart.

## PROJECT LAYOUT

```
project/
├── manifest.json       # project state and block records
├── structure.json      # document structure (chapters, source detection)
├── layouts/            # per-page layout analysis (page-001.json, ...)
├── pages/              # rendered PNG pages
├── blocks/             # cropped block images
├── snippets/           # AI-generated LaTeX snippets
├── tex/                # assembled .tex chunks
├── pdf/                # compiled PDF output
├── backgrounds/        # page background images
├── tmp/                # temporary files (schema, etc.)
└── chapter-config/     # chapter configuration
```

## PHASE 2 MODULES

| Module | Lines | Purpose |
|--------|-------|---------|
| LaTeXNormalizer | 1,970 | Symbol normalization, cross-page dedup, document class fix |
| PDFComparator | 871 | Compare original vs reconstructed PDF |
| PDFStructureScanner | 793 | Auto-detect chapter structure |
| PDFContentExtractor | 556 | PDF text extraction |
| PDFMetadataExtractor | 543 | Typography metadata (fonts, margins, paper size) |
| PDFSourceDetector | ~250 | Source format detection (latex/word/scanned) |
| PageTranscriber | 454 | AI transcription orchestrator |
| Consolidator | 259 | Phase 2 orchestrator |
| LaTeXEnvChecker | 122 | `\begin`/`\end` pair validation and repair |
| TexCompileChecker | 221 | pdflatex error log parser |

## ARCHITECTURE

```
PDFToLaTeXCore (library)        PDFToLaTeXCLI (executable)
├── PDF scanning (PDFKit)       ├── CLI commands (ArgumentParser)
├── Page rendering (CG)         └── standalone entry point
├── Block detection (Vision)
├── Source detection
├── AI transcription (external)
├── Chapter planning
├── LaTeX normalization
├── Environment checking
├── Compile checking
└── TeX assembly
```

- **PDFToLaTeXCore**: Pure library. No ArgumentParser dependency.
  Consumed by `macdoc` CLI, MCP servers, tests.
- **PDFToLaTeXCLI**: Standalone CLI entry point (`pdf-to-latex`).

## REQUIREMENTS

- macOS 14+
- Swift 5.9+
- At least one AI CLI tool (for transcription)
- pdflatex (for compilation, optional)

## EXAMPLES

Full pipeline from PDF to compilable LaTeX:

```bash
# 1. Initialize project
macdoc pdf init --pdf textbook.pdf

# 2. Detect source format
macdoc pdf detect-source textbook.pdf

# 3. Scan structure + render + detect blocks
macdoc pdf blocks --project ./textbook-project

# 4. AI transcription (10 pages at a time, 3 concurrent)
macdoc pdf transcribe --project ./textbook-project \
    --model gpt-5.4 --concurrency 3

# 5. Detect chapters and assemble
macdoc pdf chapters --project ./textbook-project
macdoc pdf assemble --project ./textbook-project

# 6. Phase 2: consolidate into compilable LaTeX
macdoc pdf consolidate --project ./textbook-project

# 7. Verify against original
macdoc pdf compare --original textbook.pdf \
    --reproduced ./textbook-project/pdf/accumulated.pdf
```

## SEE ALSO

- `macdoc(1)` — parent CLI (Word + PDF + Config)
- `macdoc pdf consolidate` — Phase 2 consolidation pipeline
- `macdoc config ai` — AI backend configuration

## AUTHORS

Che Cheng, with AI assistance (Claude Opus 4.6, GPT-5.4).
