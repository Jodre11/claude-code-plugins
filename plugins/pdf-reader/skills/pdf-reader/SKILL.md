---
name: pdf-reader
description: Extract text from any PDF — native text via poppler or scanned/image-based via tesseract OCR fallback. Use when the user wants to read, search, summarise, or extract content from a PDF file. This plugin is read-only. For PDF creation, merging, splitting, watermarking, or form filling, use office-pdf instead.
---

# PDF Reader

Extract text from any PDF using `pdf-text`. Handles both native text PDFs (via `pdftotext`) and
scanned/image-based PDFs (via `tesseract` OCR fallback). Auto-detects which method to use.

## Boundary: Read vs Write

| Task | Plugin |
|------|--------|
| Extract text, summarise, search within a PDF | **pdf-reader** (this plugin) |
| Create, merge, split, watermark, fill forms | **office-pdf** |

## When to Use

- User provides a PDF and wants the text content
- Summarising or searching within a PDF
- Extracting data from scanned documents or invoices
- Checking whether a PDF is text-based or image-based

## Usage

```bash
# Extract all text (auto-detects text vs image)
pdf-text document.pdf

# Extract specific pages
pdf-text --pages 1-5 document.pdf

# Force OCR even on text-based PDFs
pdf-text --ocr document.pdf

# Show metadata and text/image classification
pdf-text --info document.pdf
```

## Workflow

1. If the user provides a URL, download the PDF first:

       curl -sL -o $CLAUDE_TEMP_DIR/document.pdf "URL"

2. Run `pdf-text` to extract content:

       pdf-text $CLAUDE_TEMP_DIR/document.pdf

3. For large PDFs, extract in page ranges to avoid overwhelming context:

       pdf-text --pages 1-10 large-document.pdf

4. If you only need metadata or want to check the classification:

       pdf-text --info document.pdf

## Auto-Detection Logic

The tool samples the first few pages with `pdftotext`. If fewer than 50 non-whitespace characters
are found, it classifies the PDF as image-based and falls back to OCR via `tesseract` at 300 DPI.

## Flags

| Flag | Purpose |
|------|---------|
| `--pages N-M` | Extract pages N through M (inclusive, 1-based) |
| `--pages N` | Extract a single page |
| `--ocr` | Force OCR regardless of detected text |
| `--info` | Show metadata and text/image classification |
| `--version` | Show version |

## Prerequisites

- `poppler` — provides `pdftotext`, `pdfinfo`, `pdftoppm` (required)
- `tesseract` — OCR engine (required only for scanned/image-based PDFs)

Install per platform (macOS: `brew install poppler tesseract`; Debian/Ubuntu:
`apt install poppler-utils tesseract-ocr`; Fedora/RHEL: `dnf install poppler-utils tesseract`).
See plugin README for Arch and Windows.

## Common Mistakes

- Using `office-pdf` to read text from a PDF — use this plugin instead
- Reading the entire 200-page PDF at once — use `--pages` to extract in manageable chunks
- Assuming OCR failed when output looks rough — scanned PDFs vary in quality; try `--info` first
