"""The MCP server: one contract, spoken over the real protocol.

Phase 3 hands these four tools to agents nobody here controls. Two things are
tested: the server actually speaks MCP — it is started as a subprocess and
driven over stdio, because a server that imports cleanly and answers nothing is
the failure that matters — and it exposes the contract and nothing beyond it.

No model, no key, no quota: reading the corpus is free.

    .venv/bin/python3 -m unittest discover tests
"""
from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]

from teach import mcp_server  # noqa: E402
from teach.core import corpus  # noqa: E402

try:
    import mcp  # noqa: F401
    HAVE_SDK = True
except ImportError:                                               # pragma: no cover
    # An optional extra: the deployed app does not need it, so a fresh clone
    # running `make verify` must skip these rather than fail. `make mcp-setup`
    # installs it.
    HAVE_SDK = False


class Client:
    """A minimal MCP client: enough to initialise, list and call."""

    def __init__(self):
        self.proc = subprocess.Popen(
            [sys.executable, "-m", "teach.mcp_server"], cwd=REPO,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self._id = 0
        self._request("initialize", {
            "protocolVersion": "2024-11-05", "capabilities": {},
            "clientInfo": {"name": "tests", "version": "0"}})
        self._notify("notifications/initialized", {})

    def _send(self, payload):
        self.proc.stdin.write(json.dumps(payload) + "\n")
        self.proc.stdin.flush()

    def _notify(self, method, params):
        self._send({"jsonrpc": "2.0", "method": method, "params": params})

    def _request(self, method, params):
        self._id += 1
        self._send({"jsonrpc": "2.0", "id": self._id, "method": method,
                    "params": params})
        return json.loads(self.proc.stdout.readline())

    def tools(self):
        return self._request("tools/list", {})["result"]["tools"]

    def call(self, name, **arguments):
        result = self._request("tools/call",
                               {"name": name, "arguments": arguments})["result"]
        structured = result.get("structuredContent") or {}
        if "result" in structured:            # a list return
            return structured["result"]
        if structured:
            return structured
        return json.loads(result["content"][0]["text"])

    def close(self):
        self.proc.stdin.close()
        self.proc.terminate()
        self.proc.wait(timeout=10)


@unittest.skipUnless(HAVE_SDK, "MCP SDK not installed — run `make mcp-setup`")
class ProtocolTests(unittest.TestCase):
    """Started as a subprocess and driven over stdio, like a real client."""

    @classmethod
    def setUpClass(cls):
        cls.client = Client()

    @classmethod
    def tearDownClass(cls):
        cls.client.close()

    def test_it_offers_the_contract_and_nothing_else(self):
        # A fifth tool here means the bot and the MCP server have stopped being
        # the same four functions, which is the whole design of both.
        names = {t["name"] for t in self.client.tools()}
        self.assertEqual(names, {"list_certs", "get_syllabus", "get_topic",
                                 "search_topics"})

    def test_every_tool_is_described(self):
        # The description is all an agent has to choose with.
        for tool in self.client.tools():
            with self.subTest(tool=tool["name"]):
                self.assertTrue(tool.get("description"))
                self.assertIn(tool["name"], mcp_server.DESCRIPTIONS)

    def test_listing_certifications_says_which_are_empty(self):
        certs = self.client.call("list_certs")
        self.assertTrue(certs)
        self.assertTrue(all("topics" in c and "available" in c for c in certs))

    def test_a_topic_arrives_with_its_sources(self):
        topic = self.client.call("get_topic", cert="lpi-010-160", topic="5.2",
                                 lang="en")
        self.assertIn("/etc/passwd", topic["content"])
        self.assertTrue(topic["sources"])

    def test_search_carries_its_reasoning(self):
        hits = self.client.call("search_topics", query="network policies",
                                cert="cka", limit=2)
        self.assertTrue(hits)
        self.assertTrue(all(h["why"] for h in hits))
        self.assertEqual({h["cert"] for h in hits}, {"cka"})

    def test_an_unknown_certification_says_what_to_do_instead(self):
        # The SDK's own handling answers "Error executing tool get_syllabus",
        # which cannot tell a typo from an outage. An agent needs to know which
        # of those it is to decide what to do next.
        answer = self.client.call("get_syllabus", cert="does-not-exist")
        self.assertIn("error", answer)
        self.assertIn("list_certs", answer["error"])

    def test_a_bad_topic_does_not_take_the_server_down(self):
        self.client.call("get_topic", cert="lpi-010-160", topic="99.99")
        # still answering afterwards
        self.assertTrue(self.client.call("list_certs"))


class ContractTests(unittest.TestCase):
    def test_the_descriptions_cover_exactly_the_shared_contract(self):
        # teach/core/corpus.py is the one implementation; this asserts the MCP
        # half has not grown a tool of its own.
        public = {name for name in vars(corpus)
                  if callable(getattr(corpus, name)) and not name.startswith("_")
                  and getattr(corpus, name).__module__ == corpus.__name__}
        self.assertEqual(set(mcp_server.DESCRIPTIONS), public)

    def test_the_instructions_do_not_oversell_the_corpus(self):
        # Whatever else it says, an agent must be told the material is generated
        # and that the official sources are what to cite.
        self.assertIn("AI-generated", mcp_server.INSTRUCTIONS)
        self.assertIn("sources", mcp_server.INSTRUCTIONS)


if __name__ == "__main__":
    unittest.main()
