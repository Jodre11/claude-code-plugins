"""Scratch module for checking /address-pr-comments against a thin-suite review. Do not merge."""

import json


def moving_average(values, window):
    """Return the moving averages of `values` over a sliding `window`."""
    if window < 1:
        raise ValueError(f"window must be at least 1, got {window}")
    averages = []
    for i in range(len(values) - window + 1):
        averages.append(sum(values[i:i + window]) / window)
    return averages


def load_values(path):
    """Load a JSON list of numbers from `path`, or an empty list if the file cannot be read."""
    try:
        with open(path) as handle:
            values = json.load(handle)
    except OSError:
        return []
    if not isinstance(values, list) or not all(
            isinstance(v, (int, float)) and not isinstance(v, bool) for v in values):
        raise ValueError(f"{path} does not hold a JSON list of numbers")
    return values
