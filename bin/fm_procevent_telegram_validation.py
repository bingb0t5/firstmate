"""Shared validation for Telegram update identifiers."""

MAX_UPDATE_ID = 2**31 - 1


def valid_update_id(value):
    """Return whether value is a Telegram update identifier we can advance past."""
    return type(value) is int and 1 <= value <= MAX_UPDATE_ID
