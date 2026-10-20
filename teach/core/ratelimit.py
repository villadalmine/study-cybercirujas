"""A small in-process rate limiter for the public API (sliding window, per client).

Per worker and in memory: enough to stop one client from hammering `/api/search`,
not a substitute for limits at the proxy. Limits are requests per minute and can be
changed (0 turns the limit off): TEACH_RATE_API (default 300) and TEACH_RATE_SEARCH
(default 30). The client is the socket peer. Behind a proxy that appends the peer address
to X-Forwarded-For (Envoy / the Gateway API proxy of the chart does), set TEACH_TRUST_PROXY=1:
the client is then taken from the END of the header, TEACH_TRUSTED_HOPS entries from the right
(default 1 = the address the proxy itself appended). Entries further left are client-supplied
and never used, so rotating the header does not give a client a new bucket. Never set it
when the app is reachable without that proxy.
"""

import os
import threading
import time
from collections import defaultdict, deque

WINDOW = 60.0
MAX_KEYS = 10_000


def _int_env(name: str, default: int) -> int:
    try:
        return max(0, int(os.environ.get(name, default)))
    except ValueError:
        return default


API_LIMIT = _int_env("TEACH_RATE_API", 300)
SEARCH_LIMIT = _int_env("TEACH_RATE_SEARCH", 30)


class Limiter:
    def __init__(self, window: float = WINDOW, clock=time.monotonic):
        self.window, self.clock = window, clock
        self.hits: dict[str, deque] = defaultdict(deque)
        self.lock = threading.Lock()

    def hit(self, key: str, limit: int) -> int:
        """0 if the request is allowed, else the seconds to wait."""
        if limit <= 0:
            return 0
        now = self.clock()
        with self.lock:
            if len(self.hits) > MAX_KEYS:
                self.hits = defaultdict(deque, {k: v for k, v in self.hits.items()
                                                if v and now - v[-1] < self.window})
            q = self.hits[key]
            while q and now - q[0] >= self.window:
                q.popleft()
            if len(q) >= limit:
                return max(1, int(self.window - (now - q[0])) + 1)
            q.append(now)
            return 0


LIMITER = Limiter()


def client_id(request) -> str:
    if os.environ.get("TEACH_TRUST_PROXY") == "1":
        hops = max(1, _int_env("TEACH_TRUSTED_HOPS", 1))
        parts = [p.strip() for p in request.headers.get("x-forwarded-for", "").split(",") if p.strip()]
        if len(parts) >= hops:
            return parts[-hops]
    return request.client.host if request.client else "unknown"
