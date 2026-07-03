import math
import os
import sys

sys.path.insert(
    0,
    os.path.join(os.path.dirname(__file__), "..", "ab", "lib"),
)

import ab_stats  # noqa: E402


def test_fisher_clean_separation_is_significant():
    # arm A: 0/5 Important, arm B: 5/5 Important.
    p = ab_stats.fisher_exact_two_tailed(a=0, b=5, c=5, d=0)
    assert p < 0.05
    assert math.isclose(p, 0.007936507936507936, rel_tol=1e-9)


def test_fisher_no_difference_is_not_significant():
    # arm A: 3/5, arm B: 3/5 — identical, p == 1.0.
    p = ab_stats.fisher_exact_two_tailed(a=3, b=2, c=3, d=2)
    assert math.isclose(p, 1.0, rel_tol=1e-9)


def test_wilson_interval_zero_of_five():
    lo, hi = ab_stats.wilson_interval(successes=0, n=5)
    assert math.isclose(lo, 0.0, abs_tol=1e-9)
    assert 0.40 < hi < 0.46  # upper bound for 0/5 at 95% is ~0.4366


def test_wilson_interval_all_of_five():
    lo, hi = ab_stats.wilson_interval(successes=5, n=5)
    assert 0.54 < lo < 0.60
    assert math.isclose(hi, 1.0, abs_tol=1e-9)


def test_wilson_handles_zero_n():
    lo, hi = ab_stats.wilson_interval(successes=0, n=0)
    assert lo == 0.0 and hi == 0.0
