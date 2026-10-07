"""marv-mlx chat REPL.

A small streaming chat client for an mlx_vlm.server OpenAI-compatible endpoint.
It renders reasoning ("thinking") traces in grey, the answer in the default
colour, supports Esc-to-stop, Enter/Tab, chat logging and resume-from-log.

Thinking is model-family specific. The caller (marv-mlx.zsh) classifies the model
and passes:

    --control   enable_thinking | variant | none
    --markers   think | channel | bracket | none
    --reasoning-first        (reasoning trace begins immediately, e.g. Ministral)
    --thinking  default | on | off

Rules (agreed semantics):
  * "default" is treated as off — thinking is only on when explicitly "on".
  * control=enable_thinking: the toggle drives the per-request enable_thinking.
  * control=variant (Ministral): generation can't be toggled; the toggle only
    controls whether the inherent trace is displayed.
  * control=none (e.g. LFM): same display-only behaviour.
"""

import argparse
import codecs
import json
import os
import re
import select
import signal
import sys
import termios
import tty
import urllib.error
import urllib.request

# Inline reasoning delimiters per family. The server normally splits reasoning
# into `reasoning_content`; these are the fallback when it is left inline.
MARKER_PAIRS = {
    "think": (("<think>", "</think>"), (" thinking", " response")),
    "channel": (("<|channel>thought", "<channel|>"),),
    "bracket": (("[THINK]", "[/THINK]"),),
    "none": (),
}

TAIL = 10  # max bytes to hold back in case a marker straddles chunks
GRAY = "\033[2m"
RESET = "\033[0m"
ANSI = re.compile(r'\x1b\[[0-9;]*m')


def find_first(text, markers):
    """Return (index, marker) of the earliest marker in text, or (-1, "")."""
    best_idx, best = -1, ""
    for marker in markers:
        idx = text.find(marker)
        if idx >= 0 and (best_idx < 0 or idx < best_idx):
            best_idx, best = idx, marker
    return best_idx, best


def split_partial(text, markers):
    """Split off a trailing fragment that may be the start of a marker."""
    keep = 0
    for marker in markers:
        cap = min(len(marker) - 1, len(text))
        for length in range(cap, 0, -1):
            if text.endswith(marker[:length]):
                keep = max(keep, length)
                break
    if keep:
        return text[:-keep], text[-keep:]
    return text, ""


def strip_leading_opener(text, opens):
    """For reasoning-first streams, drop an optional leading opener.

    Returns (state, rest) where state is "stripped", "none" or "wait" (text is
    a prefix of an opener and more input is needed).
    """
    if not text:
        return "none", text
    for opener in opens:
        if text.startswith(opener):
            return "stripped", text[len(opener):]
    for opener in opens:
        if opener.startswith(text):
            return "wait", text
    return "none", text


class Filter:
    """Route a model's reasoning trace vs. its answer for terminal display.

    mode "show" renders the trace dim/grey; mode "strip" drops it entirely.
    Handles both the server-split path (external_reasoning, from
    `reasoning_content`) and the inline path (markers embedded in `content`).
    """

    def __init__(self, mode, markers="think", reasoning_first=False):
        self.mode = mode
        self.pairs = MARKER_PAIRS.get(markers, ())
        self.opens = tuple(o for o, _ in self.pairs)
        self.closes = tuple(c for _, c in self.pairs)
        self.reasoning_first = reasoning_first
        self.external = False          # reasoning arrives via reasoning_content
        self.in_think = reasoning_first
        self.opener_done = not reasoning_first
        self.done = not (self.pairs or reasoning_first)
        self.buf = ""
        self.labeled = False           # "thinking" header emitted
        self.broken = False            # answer break emitted

    def _thinking_head(self):
        if self.mode != "show" or self.labeled:
            return ""
        self.labeled = True
        return GRAY + "─ thinking ─" + RESET + "\n"

    def _thinking_break(self):
        if self.mode != "show" or self.broken:
            return ""
        self.broken = True
        return "\n"

    def external_reasoning(self, text):
        """Server routed the trace to reasoning_content; content is the answer."""
        body = (self.buf + text) if self.buf else text
        self.buf = ""
        self.external = True
        self.done = True
        self.in_think = False
        if self.mode != "show":
            return ""
        return self._thinking_head() + GRAY + body + RESET

    def feed_content(self, text):
        if self.external:
            return self._thinking_break() + text
        self.buf += text
        return self._feed_inline()

    def _feed_inline(self):
        out = []
        if self.reasoning_first and not self.opener_done:
            state, rest = strip_leading_opener(self.buf, self.opens)
            if state == "wait":
                return ""
            self.buf = rest
            self.opener_done = True
        if self.in_think and not self.labeled:
            out.append(self._thinking_head())
        while self.buf:
            if self.done:
                out.append(self.buf)
                self.buf = ""
                break
            if self.in_think:
                idx, close = find_first(self.buf, self.closes)
                if idx < 0:
                    emit, self.buf = split_partial(self.buf, self.closes)
                    if emit and self.mode == "show":
                        out.append(GRAY + emit + RESET)
                    break
                if self.mode == "show":
                    out.append(GRAY + self.buf[:idx] + RESET)
                out.append(self._thinking_break())
                self.buf = self.buf[idx + len(close):]
                self.in_think = False
                self.done = True
            else:
                idx, opener = find_first(self.buf, self.opens)
                if idx < 0:
                    emit, self.buf = split_partial(self.buf, self.opens)
                    out.append(emit)
                    break
                if idx:
                    out.append(self.buf[:idx])
                self.buf = self.buf[idx + len(opener):]
                self.in_think = True
                out.append(self._thinking_head())
        return "".join(out)

    def flush(self):
        rest, self.buf = self.buf, ""
        if not rest:
            return ""
        if not self.done and (self.in_think or self.reasoning_first):
            return (GRAY + rest + RESET) if self.mode == "show" else ""
        return rest


# Raised on a lone Esc while NOT mid-answer. Esc during an answer stops the
# output; Esc at the prompt leaves the chat and returns to the main menu.
class EscExit(Exception):
    pass


def build_body(model, messages, control, markers, effective, temp="", max_tokens=""):
    """Build a chat-completions request body for the resolved thinking state.

    control=enable_thinking  -> send enable_thinking (the toggle drives it)
    control=variant / none   -> generation can't be toggled; don't send it
    markers=bracket          -> tell the server how to split Ministral's trace
    """
    body = {"model": model, "messages": messages, "stream": True}
    if control == "enable_thinking":
        body["enable_thinking"] = bool(effective)
    if markers == "bracket":
        body["thinking_start_token"] = "[THINK]"
        body["thinking_end_token"] = "[/THINK]"
    if temp:
        try:
            body["temperature"] = float(temp)
        except ValueError:
            pass
    if max_tokens:
        try:
            body["max_tokens"] = int(max_tokens)
        except ValueError:
            pass
    return body


def parse_args(argv=None):
    parser = argparse.ArgumentParser(prog="marv-mlx-repl", description=__doc__)
    parser.add_argument("--url", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--system-prompt", default="")
    parser.add_argument("--thinking", choices=("default", "on", "off"), default="default")
    parser.add_argument(
        "--control",
        choices=("enable_thinking", "variant", "none"),
        default="enable_thinking",
    )
    parser.add_argument(
        "--markers", choices=("think", "channel", "bracket", "none"), default="think"
    )
    parser.add_argument("--reasoning-first", action="store_true")
    parser.add_argument("--chat-log", default="")
    parser.add_argument("--temperature", default="")
    parser.add_argument("--max-tokens", default="")
    parser.add_argument("--resume", default="")
    parser.add_argument("--sibling", default="")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    url = args.url
    model = args.model
    sibling = args.sibling
    reasoning_first = args.reasoning_first
    control = args.control
    markers = args.markers
    log_path = args.chat_log
    temp = args.temperature
    max_tokens = args.max_tokens

    # Mutable toggle state; "default" and "off" both mean thinking is off.
    st = {"thinking": args.thinking}
    flt = Filter(
        "show" if st["thinking"] == "on" else "strip",
        markers=markers,
        reasoning_first=reasoning_first,
    )
    PROMPT = "\033[1;36myou>\033[0m "

    base = ([{"role": "system", "content": args.system_prompt}] if args.system_prompt else [])
    messages = list(base)

    # Resume: seed the conversation from a previous chat log. Lines are
    # `you> …` / `assistant> …`; `(history cleared)` resets context.
    resume = args.resume
    if resume:
        try:
            with open(resume) as handle:
                for raw in handle:
                    raw = raw.rstrip("\n")
                    if raw.startswith("you> "):
                        messages.append({"role": "user", "content": raw[5:]})
                    elif raw.startswith("assistant> "):
                        content = raw[11:]
                        if content.endswith(" [stopped]"):
                            content = content[:-10]
                        messages.append({"role": "assistant", "content": content})
                    elif raw == "(history cleared)":
                        messages = list(base)
        except OSError:
            pass

    def log(msg):
        if log_path:
            try:
                with open(log_path, "a") as handle:
                    handle.write(msg + "\n")
            except OSError:
                pass

    def toggle_thinking():
        st["thinking"] = "off" if st["thinking"] == "on" else "on"
        effective = st["thinking"] == "on"
        flt.mode = "show" if effective else "strip"
        state = "on" if effective else "off"
        sys.stdout.write("\r\033[2m(thinking %s)\033[0m\r\n" % state)
        sys.stdout.flush()

    # Ctrl-T (SIGINFO) also toggles thinking when the terminal delivers it.
    try:
        signal.signal(signal.SIGINFO, lambda s, f: toggle_thinking())
    except Exception:
        pass

    # Raw-mode terminal so we can see Tab and Esc as bytes instead of cooked input.
    FD = 0
    state = {"in": ""}
    decoder = codecs.getincrementaldecoder("utf-8")("replace")

    def key_available(timeout=0.0):
        return bool(select.select([FD], [], [], timeout)[0])

    def fill(timeout=None):
        if state["in"]:
            return True
        # Incremental decoder keeps a multibyte UTF-8 char intact even if a
        # paste lands on a read() boundary (os.read may split it).
        while True:
            if not key_available(timeout):
                return False
            raw = os.read(FD, 32)
            if not raw:
                return False  # EOF
            state["in"] = decoder.decode(raw)
            if state["in"]:
                return True
            if timeout is not None:
                return False

    def next_byte(timeout=None):
        if not fill(timeout):
            return ""
        b = state["in"][0]
        state["in"] = state["in"][1:]
        return b

    def peek_byte(timeout=0.05):
        if fill(timeout):
            return state["in"][0]
        return ""

    def input_line():
        buf = ""
        sys.stdout.write(PROMPT)
        sys.stdout.flush()
        while True:
            b = next_byte(None)
            if b == "":
                raise EOFError
            if b == "\x1b":
                nxt = peek_byte(0.05)
                if nxt in ("[", "O"):
                    next_byte(0.05)  # consume the sequence introducer
                    while True:
                        nb = peek_byte(0.05)
                        if not nb:
                            break
                        next_byte(0.05)
                        if 0x40 <= ord(nb) <= 0x7E:
                            break
                raise EscExit  # lone Esc at the prompt leaves the chat
            if b in ("\r", "\n"):
                sys.stdout.write("\r\n")
                sys.stdout.flush()
                return buf
            if b == "\x03":
                sys.stdout.write("\r\n")
                sys.stdout.flush()
                raise KeyboardInterrupt
            if b == "\x04":
                sys.stdout.write("\r\n")
                sys.stdout.flush()
                raise EOFError
            if b in ("\x7f", "\x08"):
                if buf:
                    buf = buf[:-1]
                    sys.stdout.write("\b \b")
                    sys.stdout.flush()
                continue
            if b == "\t":
                if sibling:
                    if reasoning_first:
                        msg = "Switching to the instruct version…"
                    else:
                        msg = "Switching to the reasoning (thinking) version…"
                    sys.stdout.write("\r\n\033[2m%s\033[0m\r\n" % msg)
                    sys.stdout.flush()
                    sys.exit(3)
                toggle_thinking()
                sys.stdout.write(PROMPT + buf)
                sys.stdout.flush()
                continue
            buf += b
            sys.stdout.write(b)
            sys.stdout.flush()

    old_term = termios.tcgetattr(FD)
    try:
        tty.setraw(FD)
        while True:
            try:
                user = input_line()
            except EOFError:
                sys.stdout.write("\r\n")
                break
            except KeyboardInterrupt:
                sys.stdout.write("\r\n")
                break
            except EscExit:
                sys.stdout.write("\r\n")
                break
            s = user.strip()
            if not s:
                continue
            if s in ("/exit", "/quit", "exit", "quit"):
                break
            if s == "/reset":
                messages = list(base)
                sys.stdout.write("\r\n\033[2m(history cleared)\033[0m\r\n")
                sys.stdout.flush()
                log("(history cleared)")
                continue
            messages.append({"role": "user", "content": user})
            log("you> " + user)
            effective = st["thinking"] == "on"
            body = build_body(
                model, messages, control, markers, effective, temp, max_tokens
            )
            req = urllib.request.Request(
                url,
                data=json.dumps(body).encode(),
                headers={"Content-Type": "application/json"},
            )
            print("\033[1;35massistant>\033[0m ", end="", flush=True)
            full = ""
            visible = ""
            stopped = False
            try:
                with urllib.request.urlopen(req) as response:
                    for raw in response:
                        if key_available(0):
                            key = os.read(FD, 4096).decode("utf-8", "replace")
                            if "\x1b" in key:
                                stopped = True
                                break
                            state["in"] = key + state["in"]
                        line = raw.decode("utf-8", "replace").strip()
                        if not line.startswith("data:"):
                            continue
                        data = line[5:].strip()
                        if data == "[DONE]":
                            break
                        try:
                            chunk = json.loads(data)
                            delta = chunk["choices"][0]["delta"]
                            # Server may route reasoning to reasoning_content
                            # (Qwen/Gemma/Ministral with markers) or leave it
                            # inline in content.
                            reasoning = (
                                delta.get("reasoning_content")
                                or delta.get("reasoning")
                                or ""
                            )
                            content = delta.get("content") or ""
                            if reasoning:
                                full += reasoning
                                shown = flt.external_reasoning(reasoning)
                                if shown:
                                    visible += shown
                                    sys.stdout.write(shown.replace("\n", "\r\n"))
                                    sys.stdout.flush()
                            if content:
                                full += content
                                shown = flt.feed_content(content)
                                if shown:
                                    visible += shown
                                    sys.stdout.write(shown.replace("\n", "\r\n"))
                                    sys.stdout.flush()
                        except (json.JSONDecodeError, KeyError, IndexError):
                            pass
                if not stopped:
                    tail = flt.flush()
                    if tail:
                        visible += tail
                        sys.stdout.write(tail.replace("\n", "\r\n"))
                        sys.stdout.flush()
            except urllib.error.URLError as exc:
                sys.stdout.write("\r\n\033[31m[error] %s\033[0m\r\n" % exc)
                sys.stdout.flush()
                messages.pop()
                continue
            except KeyboardInterrupt:
                sys.stdout.write("\r\n\033[2m[interrupted]\033[0m\r\n")
                sys.stdout.flush()
                messages.pop()
                continue
            sys.stdout.write("\r\n")
            sys.stdout.flush()
            # Esc keeps the partial reply in history so the model has context of
            # what it already generated; only display is filtered.
            plain = ANSI.sub("", visible)
            if stopped:
                sys.stdout.write("\033[2m[stopped]\033[0m\r\n")
                sys.stdout.flush()
                log("assistant> " + plain + " [stopped]")
            else:
                log("assistant> " + plain)
            messages.append({"role": "assistant", "content": full})
    finally:
        termios.tcsetattr(FD, termios.TCSANOW, old_term)


if __name__ == "__main__":
    main()
