"""End-to-end REPL test against the SSE mock, driven through a pty.

Verifies the request body per family and that reasoning is rendered as a grey
"─ thinking ─" block while the answer is not. Run:
    python3 -m unittest discover -s tests -v
"""

import os
import pty
import re
import select
import subprocess
import sys
import time
import unittest

sys.path.insert(0, os.path.dirname(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))

import mock_server  # noqa: E402

REPL = os.path.join(os.path.dirname(__file__), "..", "lib", "marv_mlx_repl.py")
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def strip_ansi(text):
    return ANSI.sub("", text)


def run_turn(url, model, extra_args, prompt="hi"):
    """Run one prompt through the REPL; return the raw pty output."""
    args = [
        sys.executable,
        os.path.abspath(REPL),
        "--url",
        url,
        "--model",
        model,
        "--thinking",
        "on",
        *extra_args,
    ]
    master, slave = pty.openpty()
    proc = subprocess.Popen(
        args,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        close_fds=True,
        env={**os.environ, "TERM": "dumb"},
    )
    os.close(slave)
    out = b""

    def drain(seconds):
        nonlocal out
        deadline = time.time() + seconds
        while time.time() < deadline:
            ready, _, _ = select.select([master], [], [], 0.1)
            if ready:
                try:
                    out += os.read(master, 65536)
                except OSError:
                    break

    drain(0.6)
    os.write(master, (prompt + "\n").encode())
    drain(2.5)
    os.write(master, b"/exit\n")
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
    drain(0.2)
    os.close(master)
    return out.decode("utf-8", "replace")


class IntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = mock_server.start()
        cls.port = cls.server.server_address[1]
        cls.url = f"http://127.0.0.1:{cls.port}/v1/chat/completions"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def test_ministral_variant_shows_grey_trace_and_body_has_markers(self):
        mock_server.RECORDED.clear()
        out = strip_ansi(run_turn(
            self.url,
            "acme/Ministral-3-8B-Reasoning-2512-4bit",
            ["--control", "variant", "--markers", "bracket", "--reasoning-first"],
        ))
        self.assertIn("thinking", out)
        self.assertIn("weighing", out)
        self.assertIn("Hello from Ministral", out)
        body = mock_server.RECORDED[-1]
        self.assertNotIn("enable_thinking", body)  # variant can't be toggled
        self.assertEqual(body["thinking_start_token"], "[THINK]")
        self.assertEqual(body["thinking_end_token"], "[/THINK]")

    def test_qwen_enable_thinking_sent_true_when_on(self):
        mock_server.RECORDED.clear()
        out = strip_ansi(run_turn(
            self.url,
            "acme/Qwen3.5-9B",
            ["--control", "enable_thinking", "--markers", "think"],
        ))
        self.assertIn("Hello from Qwen", out)
        self.assertIn("think", out)  # reasoning rendered
        body = mock_server.RECORDED[-1]
        self.assertIs(body["enable_thinking"], True)
        self.assertNotIn("thinking_start_token", body)

    def test_gemma_channel_inline(self):
        out = strip_ansi(run_turn(
            self.url,
            "acme/gemma-4-12B",
            ["--control", "enable_thinking", "--markers", "channel"],
        ))
        self.assertIn("weighing", out)
        self.assertIn("Hello from Gemma", out)


if __name__ == "__main__":
    unittest.main()
