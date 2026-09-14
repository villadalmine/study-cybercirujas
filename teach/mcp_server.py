"""Study against this corpus from any agent — the same four functions, over MCP.

Phase 3 of docs/STUDY_BOT_DESIGN.md: "expose the same contract over MCP
(list_certs, get_syllabus, get_topic, search_topics) so any external agent can
study against the corpus. The bot's tools and the MCP tools are the same four
functions — design once, ship twice." This is the second shipping. Every tool
here is a thin wrapper over `teach.core.corpus`, which is where the behaviour
lives and where it is tested.

WHY THIS IS SAFE TO EXPOSE. An MCP server hands tools to an agent nobody here
controls. What keeps that defensible is not care, it is the contract: all four
functions are pure reads of the published corpus — the same material the site
serves to anyone without a login — and `tests/test_corpus.py` asserts the module
cannot write, spend, or reach a path that does. Nothing here adds a capability
the web already gives away; it only makes it addressable.

    .venv/bin/python3 -m teach.mcp_server        # stdio, as .mcp.json runs it

Reading the corpus costs nothing: no model, no key, no quota. The bot's own
inference is paid by the student in their browser, and none of that passes
through here.
"""
from __future__ import annotations

import functools

from .core import certs, corpus

# The four tools, described once. The signatures below carry the schema (the
# SDK derives it from the type hints), so this is the prose half and there is no
# second copy of the contract to drift from the first.
DESCRIPTIONS = {
    "list_certs": (
        "List every certification in the catalogue, with how many objectives "
        "each has and how many already have study material. A certification "
        "with topics: 0 is catalogued but not yet snapshotted."),
    "get_syllabus": (
        "The objectives of one certification: id, title, domain, exam weight, "
        "whether material exists and in which languages. Small enough to read "
        "whole — fifteen to forty entries — so prefer it over searching when "
        "the certification is known."),
    "get_topic": (
        "The study material for one objective: theory, exercises, the official "
        "sources it was written from, and which model wrote it. Falls back to "
        "another language when the requested one is missing, and says so in "
        "lang_fallback."),
    "search_topics": (
        "Which objectives mention something, ranked, across every certification "
        "or within one. Every hit carries `why` it matched. Keyword search over "
        "syllabus titles and domains — it will not find a term that appears only "
        "in the body of the material."),
}

INSTRUCTIONS = (
    "Study material for IT certifications: 38 certifications, 726 objectives, "
    "in seven languages. Read a syllabus whole before searching — for one "
    "certification it is fifteen to forty entries. Everything is AI-generated "
    "and carries the official sources it was written from; cite those rather "
    "than this corpus.")


def _readable(call):
    """Turn a lookup failure into something the agent can act on.

    The SDK's own handling answers `Error executing tool get_syllabus`, which
    tells an agent nothing: it cannot tell a typo in a certification id from a
    server that is down, so it cannot decide whether retrying or asking
    differently is the move. The identifiers it got wrong are not secret — they
    are on the public site — so naming them costs nothing and saves a round trip.
    """
    @functools.wraps(call)
    def wrapped(*args, **kwargs):
        try:
            return call(*args, **kwargs)
        except (KeyError, FileNotFoundError) as error:
            return {"error": f"not found: {error}. Use list_certs to see what "
                             f"exists, or get_syllabus for the objective ids of "
                             f"one certification."}
    return wrapped


def serve() -> None:
    """Run the stdio server, as `.mcp.json` starts it."""
    from mcp.server.mcpserver import MCPServer

    server = MCPServer("teach-plat", instructions=INSTRUCTIONS)

    @server.tool(name="list_certs", description=DESCRIPTIONS["list_certs"])
    @_readable
    def list_certs() -> list[dict]:
        return corpus.list_certs()

    @server.tool(name="get_syllabus", description=DESCRIPTIONS["get_syllabus"])
    @_readable
    def get_syllabus(cert: str) -> dict:
        return corpus.get_syllabus(cert)

    @server.tool(name="get_topic", description=DESCRIPTIONS["get_topic"])
    @_readable
    def get_topic(cert: str, topic: str, lang: str = certs.DEFAULT_LANG) -> dict:
        return corpus.get_topic(cert, str(topic), lang)

    @server.tool(name="search_topics", description=DESCRIPTIONS["search_topics"])
    @_readable
    def search_topics(query: str, cert: str | None = None,
                      limit: int = corpus.DEFAULT_LIMIT) -> list[dict]:
        return corpus.search_topics(query, cert, limit)

    server.run("stdio")


if __name__ == "__main__":
    serve()
