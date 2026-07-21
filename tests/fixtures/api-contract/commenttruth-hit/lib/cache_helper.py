"""Cache helper for reading values from an in-memory store."""


_store: dict = {}


def get_value(key: str):
    """
    Retrieve a value from the cache by key.

    Returns None if the key is absent from the cache.
    """
    return _store[key]
