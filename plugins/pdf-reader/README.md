# PDF Reader Plugin

Extract text from any PDF file. Auto-detects native text PDFs (fast extraction via `pdftotext`)
and scanned/image-based PDFs (OCR fallback via `tesseract`). Read-only — for PDF creation,
merging, splitting, or manipulation, use the `office-pdf` plugin.

## Usage

The skill triggers automatically when Claude Code needs to extract text from a PDF, or can be
invoked explicitly with `/pdf-reader`.

## Prerequisites

`poppler` provides `pdftotext`, `pdfinfo`, and `pdftoppm` (required for all extraction).
`tesseract` provides OCR (required only for scanned/image-based PDFs).

| Platform              | Poppler                    | Tesseract                  |
|-----------------------|----------------------------|----------------------------|
| macOS (Homebrew)      | `brew install poppler`     | `brew install tesseract`   |
| Debian / Ubuntu       | `apt install poppler-utils`| `apt install tesseract-ocr`|
| Fedora / RHEL         | `dnf install poppler-utils`| `dnf install tesseract`    |
| Arch Linux            | `pacman -S poppler`        | `pacman -S tesseract`      |
| Windows (Chocolatey)  | `choco install poppler`    | `choco install tesseract`  |
| Windows (Scoop)       | `scoop install poppler`    | `scoop install tesseract`  |

## Installation

    claude plugins install pdf-reader@jodre11-plugins

The `pdf-text` wrapper in `bin/` is used automatically by the skill.

## Examples

```bash
# Extract all text
pdf-text document.pdf

# Extract pages 1-5 only
pdf-text --pages 1-5 document.pdf

# Force OCR on a text-based PDF
pdf-text --ocr document.pdf

# Show metadata and text/image classification
pdf-text --info document.pdf
```

## How It Works

1. Runs `pdftotext` on a sample of pages to check for extractable native text
2. If 50+ non-whitespace characters are found, extracts using `pdftotext -layout`
3. Otherwise, renders pages to images at 300 DPI via `pdftoppm` and runs `tesseract` OCR
4. `--ocr` flag bypasses auto-detection and forces the OCR path
