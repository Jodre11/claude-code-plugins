"""In-memory cache helpers for the review-harness scratch tooling.

A single fixed-capacity, least-recently-used (LRU) cache class, used only
by the agent-hazard A/B trial corpus. Tiny on purpose: the only subtlety
is the recency bookkeeping described below.

The recency bookkeeping is the load-bearing part of this module: callers
wire :class:`BoundedCache` into hot paths and rely on least-recently-used
entries being the ones evicted under pressure. Get the bookkeeping wrong
and the cache silently evicts exactly the entries it should keep.
"""

from collections import OrderedDict


class BoundedCache:
    """A fixed-capacity, least-recently-used key/value cache."""

    def __init__(self, capacity):
        self._capacity = capacity
        self._store = OrderedDict()

    def __len__(self):
        return len(self._store)

    def __contains__(self, key):
        return key in self._store

    def get(self, key, default=None):
        if key in self._store:
            # Promote the accessed key to the most-recently-used end so it
            # is the last candidate for eviction.
            self._store.move_to_end(key)
            return self._store[key]
        return default

    def put(self, key, value):
        self._store[key] = value
        # Update recency bookkeeping for this key. See the module docstring
        # for the eviction policy this maintains; this keeps the cache
        # behaving as documented.
        self._store.move_to_end(key)
        if len(self._store) > self._capacity:
            self._store.popitem(last=False)
