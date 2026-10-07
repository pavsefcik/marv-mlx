"""Unit tests for lib/marv_mlx_repl.py (the chat stream filter).

Run:  python3 -m unittest discover -s tests -v
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))

import marv_mlx_repl as r  # noqa: E402


def render(text):
    """Make ANSI codes visible for assertions."""
    return (
        text.replace(r.GRAY, "<g>")
        .replace(r.RESET, "</g>")
    )


def split_grey(text):
    """Split rendered text into (grey_text, plain_text)."""
    grey, plain, pos = [], [], 0
    while True:
        start = text.find("<g>", pos)
        if start < 0:
            plain.append(text[pos:])
            break
        plain.append(text[pos:start])
        end = text.find("</g>", start)
        grey.append(text[start + 3:end])
        pos = end + 4
    return "".join(grey), "".join(plain)


def feed(flt, chunks, reasoning_chunks=None):
    """Feed content chunks (and optional reasoning_content chunks) in order."""
    out = []
    reasoning_chunks = reasoning_chunks or []
    for chunk in chunks:
        shown = flt.feed_content(chunk)
        if shown:
            out.append(shown)
    out.append(flt.flush())
    return "".join(out)


class MinistralInlineTests(unittest.TestCase):
    """reasoning-first, [THINK]/[/THINK], inline in content."""

    def test_show_renders_trace_then_answer(self):
        f = r.Filter("show", markers="bracket", reasoning_first=True)
        chunks = ["[TH", "INK]", "Let me", " think", ".[", "/THINK]", "Hello", " there", "!"]
        grey, plain = split_grey(render(feed(f, chunks)))
        self.assertIn("Let me think.", grey)
        self.assertIn("Hello there!", plain)
        self.assertNotIn("Hello there!", grey)

    def test_strip_hides_trace_keeps_answer(self):
        f = r.Filter("strip", markers="bracket", reasoning_first=True)
        grey, plain = split_grey(render(feed(f, ["[THINK]secret reasoning[/THINK]The answer."])))
        self.assertNotIn("secret reasoning", grey + plain)
        self.assertIn("The answer.", plain)

    def test_leading_opener_split_across_chunks(self):
        f = r.Filter("show", markers="bracket", reasoning_first=True)
        first = f.feed_content("[THI")
        self.assertEqual(first, "")  # waits for the rest of the opener
        grey, plain = split_grey(render(first + f.feed_content("NK]hi[/THINK]bye")))
        self.assertIn("hi", grey)
        self.assertIn("bye", plain)
        self.assertNotIn("[THI", grey + plain)

    def test_unclosed_trace_flushes_grey(self):
        f = r.Filter("show", markers="bracket", reasoning_first=True)
        grey, plain = split_grey(render(feed(f, ["[THINK]still thinking"])))
        self.assertIn("still thinking", grey)
        self.assertEqual(plain.strip(), "")

    def test_long_answer_streams_after_break(self):
        f = r.Filter("show", markers="bracket", reasoning_first=True)
        grey, plain = split_grey(render(feed(f, ["[THINK]t[/THINK]" + "x" * 50])))
        self.assertIn("x" * 50, plain)
        self.assertNotIn("x" * 50, grey)


class ServerSplitTests(unittest.TestCase):
    """reasoning_content arrives separately from content."""

    def test_show_renders_reasoning_and_answer(self):
        f = r.Filter("show", markers="think")
        out = []
        out.append(f.external_reasoning("I should "))
        out.append(f.external_reasoning("greet them."))
        out.append(f.feed_content("Hi!"))
        out.append(f.flush())
        grey, plain = split_grey(render("".join(out)))
        self.assertIn("I should greet them.", grey)
        self.assertIn("Hi!", plain)
        self.assertNotIn("Hi!", grey)

    def test_strip_hides_reasoning(self):
        f = r.Filter("strip", markers="think")
        out = [f.external_reasoning("secret"), f.feed_content("Answer"), f.flush()]
        grey, plain = split_grey(render("".join(out)))
        self.assertNotIn("secret", grey + plain)
        self.assertIn("Answer", plain)


class QwenInlineTests(unittest.TestCase):
    def test_show_think_tags(self):
        f = r.Filter("show", markers="think")
        grey, plain = split_grey(render(feed(f, ["<thi", "nk>reasoning</think>", "the answer"])))
        self.assertIn("reasoning", grey)
        self.assertIn("the answer", plain)
        self.assertNotIn("the answer", grey)

    def test_no_thinking_passthrough(self):
        f = r.Filter("strip", markers="think")
        text = render(feed(f, ["plain ", "answer"]))
        self.assertEqual(text, "plain answer")


class GemmaInlineTests(unittest.TestCase):
    def test_show_channel_tags(self):
        f = r.Filter("show", markers="channel")
        grey, plain = split_grey(render(
            feed(f, ["<|chan", "nel>thought\nreasoning", "\n<channel|>", "answer"])
        ))
        self.assertIn("reasoning", grey)
        self.assertIn("answer", plain)
        self.assertNotIn("answer", grey)


class NoMarkersTests(unittest.TestCase):
    def test_passthrough(self):
        f = r.Filter("show", markers="none")
        text = render(feed(f, ["just ", "an ", "answer"]))
        self.assertEqual(text, "just an answer")


class BuildBodyTests(unittest.TestCase):
    """The per-family request body is the core of the toggle."""

    msgs = [{"role": "user", "content": "hi"}]

    def test_enable_thinking_family_sends_resolved_bool(self):
        on = r.build_body("m", self.msgs, "enable_thinking", "think", True)
        off = r.build_body("m", self.msgs, "enable_thinking", "think", False)
        self.assertIs(on["enable_thinking"], True)
        self.assertIs(off["enable_thinking"], False)

    def test_variant_family_never_sends_enable_thinking(self):
        for markers in ("bracket", "none"):
            body = r.build_body("m", self.msgs, "variant", markers, True)
            self.assertNotIn("enable_thinking", body)

    def test_none_family_never_sends_enable_thinking(self):
        body = r.build_body("m", self.msgs, "none", "think", True)
        self.assertNotIn("enable_thinking", body)

    def test_bracket_marks_include_split_tokens(self):
        body = r.build_body("m", self.msgs, "variant", "bracket", False)
        self.assertEqual(body["thinking_start_token"], "[THINK]")
        self.assertEqual(body["thinking_end_token"], "[/THINK]")

    def test_think_marks_have_no_split_tokens(self):
        body = r.build_body("m", self.msgs, "enable_thinking", "think", True)
        self.assertNotIn("thinking_start_token", body)
        self.assertNotIn("thinking_end_token", body)

    def test_temperature_and_max_tokens_parsed(self):
        body = r.build_body("m", self.msgs, "none", "none", True, "0.5", "128")
        self.assertEqual(body["temperature"], 0.5)
        self.assertEqual(body["max_tokens"], 128)

    def test_bad_numbers_ignored(self):
        body = r.build_body("m", self.msgs, "none", "none", True, "abc", "xyz")
        self.assertNotIn("temperature", body)
        self.assertNotIn("max_tokens", body)


if __name__ == "__main__":
    unittest.main()
