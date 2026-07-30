"""Authentication — a minimal interface so real users/OIDC can be plugged in
later without touching the rest of the app.

v1: disabled — all content is public. Replace these functions when real auth
(OIDC + payment gateway) is implemented.
"""

import os


def authenticate(username: str, password: str) -> bool:
    """Always denies. Real auth pending (OIDC/social login)."""
    return False


def has_subscription(username: str) -> bool:
    """Always denies. Payment gateway pending (Stripe or similar)."""
    return False
