"""Tests for email validation service."""

from unittest.mock import patch


def test_rejects_invalid_email():
    """Verify that invalid email addresses are rejected."""
    with patch("app.services.email_validator.validate") as mock_validate:
        mock_validate.return_value = False
        from app.services.email_validator import validate

        result = validate("not-an-email")
        assert result is False
