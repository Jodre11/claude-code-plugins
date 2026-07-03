"""Exact small-sample statistics for the agent-hazard A/B trial.

Stdlib only. The 2x2 table is laid out as:

                Important   not-Important
    arm A          a              b
    arm B          c              d
"""

from math import comb, sqrt


def _hypergeom_pmf(a, b, c, d):
    """P(this exact table | fixed margins), the hypergeometric weight."""
    row1 = a + b
    row2 = c + d
    col1 = a + c
    n = a + b + c + d
    return (comb(row1, a) * comb(row2, c)) / comb(n, col1)


def fisher_exact_two_tailed(a, b, c, d):
    """Two-tailed Fisher's exact p-value for a 2x2 table.

    Sums the probability of every table (with the same margins) whose
    hypergeometric weight is <= that of the observed table.
    """
    n = a + b + c + d
    if n == 0:
        return 1.0
    row1 = a + b
    col1 = a + c
    observed = _hypergeom_pmf(a, b, c, d)
    tol = observed * (1 + 1e-7)
    total = 0.0
    a_min = max(0, col1 - (c + d))
    a_max = min(row1, col1)
    for ai in range(a_min, a_max + 1):
        bi = row1 - ai
        ci = col1 - ai
        di = (c + d) - ci
        if bi < 0 or ci < 0 or di < 0:
            continue
        p = _hypergeom_pmf(ai, bi, ci, di)
        if p <= tol:
            total += p
    return min(1.0, total)


def wilson_interval(successes, n, z=1.959963984540054):
    """Wilson score 95% confidence interval for a binomial proportion."""
    if n == 0:
        return (0.0, 0.0)
    phat = successes / n
    denom = 1 + z * z / n
    centre = (phat + z * z / (2 * n)) / denom
    margin = (z * sqrt(phat * (1 - phat) / n + z * z / (4 * n * n))) / denom
    return (max(0.0, centre - margin), min(1.0, centre + margin))
