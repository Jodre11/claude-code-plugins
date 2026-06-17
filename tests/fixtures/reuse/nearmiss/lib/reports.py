"""Report generation helpers."""


def generate_report_filename(title: str) -> str:
    """Return a filesystem-safe filename for a report with *title*."""
    slug = title.lower().replace(" ", "-")
    return f"{slug}.pdf"
