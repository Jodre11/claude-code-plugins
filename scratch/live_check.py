"""Scratch file for the /address-pr-comments live check. Do not merge."""


def parse_port(value):
    """Return *value* as a TCP port number, rejecting values outside 1-65535."""
    port = int(value)
    if not 1 <= port <= 65535:
        raise ValueError(f"port out of range: {port}")
    return port


def average(values):
    """Return the mean of *values*."""
    if not values:
        raise ValueError("average() of an empty sequence")
    return sum(values) / len(values)
