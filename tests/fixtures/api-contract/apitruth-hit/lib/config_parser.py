"""Config parser that loads JSON configuration from a file."""

import json


def load_config(path: str) -> dict:
    """Load and parse a JSON config file, returning the parsed dict."""
    with open(path, "r") as f:
        raw = f.read()
    return json.loads(raw, strict_mode=True)
