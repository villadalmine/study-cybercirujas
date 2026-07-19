"""Autenticación — interfaz mínima para poder enchufar usuarios reales/OIDC
después sin tocar el resto de la app.

v1: deshabilitado — todo el contenido es público. Cuando se implemente auth
real (OIDC + pasarela de pago), reemplazar estas funciones.
"""

import os


def authenticate(username: str, password: str) -> bool:
    """Siempre rechaza. Auth real pendiente (OIDC/social login)."""
    return False


def has_subscription(username: str) -> bool:
    """Siempre rechaza. Pasarela de pago pendiente (Stripe/similar)."""
    return False
