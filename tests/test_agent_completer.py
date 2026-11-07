"""Non-Claude CLI backends record their own provenance and never inherit Claude's pin.

`pipeline.yaml` declares `generation.model` for the default `claude` backend.
Before #269, `_agent_completer` read that pin unconditionally, so running with
`--backend gemini`, `codex` or `custom` wrote `model: claude-opus-5-5` into
`meta.yaml` while invoking another CLI.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

import quota  # noqa: E402
from teach.core import generator


class AgentCompleterProvenanceTest(unittest.TestCase):
    def setUp(self):
        self.which = mock.patch("teach.core.generator.shutil.which", return_value="/usr/bin/fake")
        self.which.start()
        self.addCleanup(self.which.stop)

    def test_claude_keeps_the_declared_model_and_effort_flags(self):
        env = {k: v for k, v in os.environ.items() if not k.startswith("TEACH_CLAUDE_")}
        with mock.patch.dict(os.environ, env, clear=True):
            with mock.patch.object(generator.pipeline, "generation",
                                   return_value={"model": "claude-opus-5-5", "effort": "high"}):
                complete, meta = generator._agent_completer("claude")
                self.assertEqual(meta, {"backend": "claude", "model": "claude-opus-5-5"})
                envelope = {
                    "result": "# Heading\n\nok",
                    "num_turns": 1,
                    "usage": {"output_tokens": 12},
                    "modelUsage": {"claude-opus-5-5": {"outputTokens": 12}},
                }
                proc = subprocess.CompletedProcess(args=[], returncode=0,
                                                   stdout=json.dumps(envelope), stderr="")
                with mock.patch("teach.core.generator.subprocess.run", return_value=proc) as run, \
                     mock.patch("teach.core.generator._record_usage"):
                    out = complete("sys", "usr")
        self.assertEqual(out, "# Heading\n\nok")
        cmd = run.call_args[0][0]
        self.assertIn("--model", cmd)
        self.assertEqual(cmd[cmd.index("--model") + 1], "claude-opus-5-5")
        self.assertIn("--effort", cmd)
        self.assertEqual(cmd[cmd.index("--effort") + 1], "high")
        self.assertEqual(cmd[-2], "--")

    def test_codex_and_custom_never_inherit_the_claude_model(self):
        env = {"TEACH_AGENT_CMD": "my-cli --flag"}
        with mock.patch.dict(os.environ, env, clear=True):
            with mock.patch.object(generator.pipeline, "generation",
                                   return_value={"model": "claude-opus-5-5", "effort": "high"}):
                _, codex_meta = generator._agent_completer("codex")
                _, custom_meta = generator._agent_completer("custom")
        self.assertEqual(codex_meta, {"backend": "codex", "model": "codex"})
        self.assertEqual(custom_meta, {"backend": "custom", "model": "my-cli"})

    def test_custom_records_explicit_model_flag_when_present(self):
        env = {"TEACH_AGENT_CMD": "my-cli --model qwen-coder-32b --exec"}
        with mock.patch.dict(os.environ, env, clear=True):
            with mock.patch.object(generator.pipeline, "generation",
                                   return_value={"model": "claude-opus-5-5"}):
                _, meta = generator._agent_completer("custom")
        self.assertEqual(meta, {"backend": "custom", "model": "qwen-coder-32b"})

    def test_gemini_pins_model_before_print_flag_and_parses_agy_json_envelope(self):
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("TEACH_CLAUDE_", "TEACH_GEMINI_"))}
        with mock.patch.dict(os.environ, env, clear=True):
            with mock.patch.object(generator.pipeline, "generation",
                                   return_value={"model": "claude-opus-5-5", "effort": "high"}):
                complete, meta = generator._agent_completer("gemini")
                self.assertEqual(meta, {
                    "backend": "gemini",
                    "model": generator.DEFAULT_GEMINI_MODEL,
                })
                agy_envelope = {
                    "conversation_id": "conv-1",
                    "status": "SUCCESS",
                    "response": "  # Architecture\n\nBody text.  \n",
                    "duration_seconds": 4.25,
                    "num_turns": 1,
                    "usage": {
                        "input_tokens": 1200,
                        "output_tokens": 450,
                        "thinking_tokens": 80,
                        "total_tokens": 1730,
                    },
                }
                proc = subprocess.CompletedProcess(args=[], returncode=0,
                                                   stdout=json.dumps(agy_envelope), stderr="")
                with mock.patch("teach.core.generator.subprocess.run", return_value=proc) as run, \
                     mock.patch("teach.core.generator._record_plain_usage") as rec:
                    answer = complete("sys", "usr")
        self.assertEqual(answer, "# Architecture\n\nBody text.")
        cmd = run.call_args[0][0]
        # Every flag on `agy` must precede `-p`, because `-p` consumes the next argv token.
        self.assertIn("--disable-slash-commands", cmd)
        p_idx = cmd.index("-p")
        m_idx = cmd.index("--model")
        self.assertLess(m_idx, p_idx)
        self.assertEqual(cmd[m_idx + 1], generator.DEFAULT_GEMINI_MODEL)
        self.assertNotIn("--effort", cmd)
        self.assertEqual(p_idx, len(cmd) - 2)
        rec.assert_called_once()
        self.assertEqual(rec.call_args[0], ("gemini", generator.DEFAULT_GEMINI_MODEL))
        self.assertEqual(rec.call_args[1]["input_tokens"], 1200)
        self.assertEqual(rec.call_args[1]["output_tokens"], 450)
        self.assertEqual(rec.call_args[1]["duration_ms"], 4250)

    def test_gemini_env_override_beats_default_and_rejects_split_turns(self):
        with mock.patch.dict(os.environ, {"TEACH_GEMINI_MODEL": "gemini-3.8-flash-high"}, clear=True):
            with mock.patch.object(generator.pipeline, "generation",
                                   return_value={"model": "claude-opus-5-5"}):
                complete, meta = generator._agent_completer("gemini")
                self.assertEqual(meta["model"], "gemini-3.8-flash-high")
                split_envelope = {
                    "status": "SUCCESS",
                    "response": "# Tail only",
                    "num_turns": 2,
                    "usage": {"input_tokens": 100, "output_tokens": 50},
                }
                proc = subprocess.CompletedProcess(args=[], returncode=0,
                                                   stdout=json.dumps(split_envelope), stderr="")
                with mock.patch("teach.core.generator.subprocess.run", return_value=proc):
                    with self.assertRaises(generator.GeneratorConfigError) as ctx:
                        complete("sys", "usr")
                self.assertIn("num_turns=2", str(ctx.exception))

    def test_gemini_error_envelope_raises_generator_config_error(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            complete, _ = generator._agent_completer("gemini")
            err_envelope = {
                "status": "ERROR",
                "response": "",
                "error": "quota exhausted",
                "num_turns": 0,
            }
            proc = subprocess.CompletedProcess(args=[], returncode=0,
                                               stdout=json.dumps(err_envelope), stderr="")
            with mock.patch("teach.core.generator.subprocess.run", return_value=proc):
                with self.assertRaises(generator.GeneratorConfigError) as ctx:
                    complete("sys", "usr")
            self.assertIn("quota exhausted", str(ctx.exception))

    def test_gemini_oversized_prompt_raises_generator_config_error(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            complete, _ = generator._agent_completer("gemini")
            oversized = "x" * (generator._ARGV_LIMIT_POSIX_BYTES + 100)
            with self.assertRaises(generator.GeneratorConfigError) as ctx:
                complete(oversized, "")
            self.assertIn("exceeds the argv limit for 'agy'", str(ctx.exception))



class QuotaProbeCommandTest(unittest.TestCase):
    def test_probe_claude_pins_haiku_before_terminator(self):
        proc = subprocess.CompletedProcess(args=[], returncode=0, stdout="OK", stderr="")
        with mock.patch.object(quota.subprocess, "run", return_value=proc) as run:
            status, detail = quota.probe("claude")
        self.assertEqual(status, quota.AVAILABLE)
        self.assertEqual(detail, "OK")
        cmd = run.call_args[0][0]
        self.assertIn("--model", cmd)
        m_idx = cmd.index("--model")
        self.assertEqual(cmd[m_idx + 1], "haiku")
        self.assertEqual(cmd[-2], "--")
        self.assertEqual(cmd[-1], quota.PROBE_PROMPT)

    def test_probe_gemini_pins_cheap_flash_model_before_print_flag(self):
        agy_env = {"status": "SUCCESS", "response": "OK", "usage": {}}
        proc = subprocess.CompletedProcess(args=[], returncode=0, stdout=json.dumps(agy_env), stderr="")
        with mock.patch.object(quota.subprocess, "run", return_value=proc) as run:
            status, detail = quota.probe("gemini")
        self.assertEqual(status, quota.AVAILABLE)
        self.assertEqual(detail, "OK")
        cmd = run.call_args[0][0]
        self.assertIn("--disable-slash-commands", cmd)
        p_idx = cmd.index("-p")
        m_idx = cmd.index("--model")
        self.assertLess(m_idx, p_idx)
        self.assertEqual(cmd[m_idx + 1], "gemini-3.8-flash-low")
        self.assertEqual(cmd[-2], "-p")
        self.assertEqual(cmd[-1], quota.PROBE_PROMPT)

    def test_probe_gemini_error_envelope_maps_to_exhausted(self):
        err_env = {"status": "ERROR", "error": "Resource exhausted: usage limit reached"}
        proc = subprocess.CompletedProcess(args=[], returncode=0, stdout=json.dumps(err_env), stderr="")
        with mock.patch.object(quota.subprocess, "run", return_value=proc):
            status, detail = quota.probe("gemini")
        self.assertEqual(status, quota.EXHAUSTED)
        self.assertIn("usage limit", detail)


if __name__ == "__main__":
    unittest.main()
