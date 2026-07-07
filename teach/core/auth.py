"""Autenticación — interfaz mínima para poder enchufar usuarios reales/OIDC
después sin tocar el resto de la app.

v1: admin/admin hardcodeado, SOLO para probar.
"""


def authenticate(username: str, password: str) -> bool:
    return username == "admin" and password == "admin"


def has_subscription(username: str) -> bool:
    """v1: stub — el admin siempre tiene plan activo. Acá se enchufa la
    pasarela de pago (Stripe/similar) cuando exista."""
    return username == "admin"
