"""Tests for the tax_calculator module."""

from tax_calculator import calculate_tax


def test_standard_tax():
    assert calculate_tax(100.0) == 20.0


def test_exempt_returns_zero():
    assert calculate_tax(100.0, exempt=True) == 0.0
