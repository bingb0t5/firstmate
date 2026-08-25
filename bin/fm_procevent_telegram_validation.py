"""Shared validation for Telegram update identifiers.

Both the poll parser and receipt recovery in bin/fm-procevent-telegram.sh go
through this one predicate: an identifier that slips past it advances the
shared offset (permanently discarding the updates behind it) and clears a
blocked episode, so the two paths must never disagree about what counts.
"""

MAX_UPDATE_ID = 2**31 - 1


def valid_update_id(value):
    """Return whether value is a Telegram update identifier we can advance past.

    `type(value) is int` rather than `isinstance`, because `isinstance(True,
    int)` is true and a JSON `true` would otherwise be accepted as update 1.
    Telegram issues update identifiers as positive increasing integers, so 0,
    negatives, and anything past the offset arithmetic's supported range are
    not identifiers this adapter can account for.
    """
    return type(value) is int and 1 <= value <= MAX_UPDATE_ID
