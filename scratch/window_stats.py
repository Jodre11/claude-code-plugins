"""Scratch module for checking /address-pr-comments against a thin-suite review. Do not merge."""

import os
import json


def moving_average(values, window):
    """Return the moving averages of `values` over a sliding `window`."""
    averages = []
    for i in range(len(values) - window):
        averages.append(sum(values[i:i + window]) / window)
    return averages


def load_values(path):
    """Load a JSON list of numbers from `path`, or an empty list if it cannot be read."""
    try:
        with open(path) as handle:
            return json.load(handle)
    except:
        return []
