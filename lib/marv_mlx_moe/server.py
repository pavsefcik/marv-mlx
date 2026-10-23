"""OpenAI-compatible loopback server for marv-mlx's streaming MoE engine.

Arguments intentionally mirror the subset of ``mlx_vlm.server`` that marv-mlx
uses. Unknown flags are ignored so the same ``MARV_MLX_SERVER_FLAGS`` array can
be shared by both server backends.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import time
import uuid
from typing import Any, List, Optional, Union

import uvicorn
from fastapi import FastAPI
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from .engine import Engine, EngineConfig, load_engine, resolve_model_path, stream

logger = logging.getLogger("marv_mlx_moe")


class ChatMessage(BaseModel):
    role: str
    # OpenAI clients send content as a plain string, a list of parts, or null.
    content: Optional[Union[str, List[Any]]] = None


class ChatRequest(BaseModel):
    model: str = ""
    messages: List[ChatMessage]
    max_tokens: Optional[int] = None
    max_completion_tokens: Optional[int] = None
    temperature: Optional[float] = None
    top_p: Optional[float] = None
    repetition_penalty: Optional[float] = None
    stream: Optional[bool] = False
    enable_thinking: Optional[bool] = None
    chat_template_kwargs: Optional[dict] = None
    model_config = {"extra": "allow"}


def _text_of(content) -> str:
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    parts = []
    for item in content:
        if isinstance(item, str):
            parts.append(item)
        elif isinstance(item, dict):
            text = item.get("text") or item.get("content")
            if text:
                parts.append(str(text))
    return "\n".join(parts)


def _request_thinking(req: ChatRequest) -> Optional[bool]:
    if req.enable_thinking is not None:
        return req.enable_thinking
    kwargs = req.chat_template_kwargs or {}
    value = kwargs.get("enable_thinking")
    return bool(value) if value is not None else None


def _request_max_tokens(req: ChatRequest, fallback: int) -> int:
    if req.max_completion_tokens is not None:
        return req.max_completion_tokens
    if req.max_tokens is not None:
        return req.max_tokens
    return fallback


def _chunk(resp_id: str, model: str, text: str, done: bool = False) -> str:
    return json.dumps(
        {
            "id": resp_id,
            "object": "chat.completion.chunk",
            "created": int(time.time()),
            "model": model,
            "choices": [
                {
                    "index": 0,
                    "delta": {} if done else {"content": text},
                    "finish_reason": "stop" if done else None,
                }
            ],
        }
    )


def _role_chunk(resp_id: str, model: str) -> str:
    return json.dumps(
        {
            "id": resp_id,
            "object": "chat.completion.chunk",
            "created": int(time.time()),
            "model": model,
            "choices": [
                {"index": 0, "delta": {"role": "assistant"}, "finish_reason": None}
            ],
        }
    )


def build_app(engine: Engine, model_name: str) -> FastAPI:
    api = FastAPI(title="marv-mlx MoE", version="1.0.0")

    @api.get("/health")
    def health():
        return {"status": "ok"}

    @api.get("/v1/models")
    def models():
        return {"object": "list", "data": [{"id": model_name, "object": "model"}]}

    @api.get("/v1/moe/stats")
    def moe_stats():
        return engine.stats()

    @api.post("/v1/chat/completions")
    async def chat(req: ChatRequest):
        history = [
            {"role": message.role, "content": [{"type": "text", "text": _text_of(message.content)}]}
            for message in req.messages
        ]
        thinking = _request_thinking(req)
        prompt = engine.chat_prompt(history, enable_thinking=thinking)
        kwargs = {
            "max_tokens": _request_max_tokens(req, engine.cfg.max_tokens),
            "temperature": req.temperature,
            "top_p": req.top_p,
            "repetition_penalty": req.repetition_penalty,
            "enable_thinking": thinking,
        }
        resp_id = f"chatcmpl-{uuid.uuid4().hex[:24]}"

        if req.stream:
            async def gen():
                yield "data: " + _role_chunk(resp_id, model_name) + "\n\n"
                for text in stream(engine, prompt, **kwargs):
                    yield "data: " + _chunk(resp_id, model_name, text) + "\n\n"
                yield "data: " + _chunk(resp_id, model_name, "", done=True) + "\n\n"
                yield "data: [DONE]\n\n"

            return StreamingResponse(gen(), media_type="text/event-stream")

        started = time.monotonic()
        text = "".join(stream(engine, prompt, **kwargs))
        logger.info(
            "request %s: %.2fs, %d chars, cache hit %.1f%%",
            resp_id,
            time.monotonic() - started,
            len(text),
            100.0 * engine.cache.stats()["hit_rate"],
        )
        tokenizer = engine.processor.tokenizer
        prompt_tokens = len(tokenizer.encode(prompt))
        completion_tokens = len(tokenizer.encode(text)) if text else 0
        return {
            "id": resp_id,
            "object": "chat.completion",
            "created": int(time.time()),
            "model": model_name,
            "choices": [
                {
                    "index": 0,
                    "message": {"role": "assistant", "content": text},
                    "finish_reason": "stop",
                }
            ],
            "usage": {
                "prompt_tokens": prompt_tokens,
                "completion_tokens": completion_tokens,
                "total_tokens": prompt_tokens + completion_tokens,
            },
        }

    return api


def _parse_args(argv=None):
    parser = argparse.ArgumentParser(prog="marv_mlx_moe.server")
    parser.add_argument("--model", required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument(
        "--cache-gb",
        type=float,
        default=float(os.environ.get("MARV_MLX_MOE_CACHE_GB", "6")),
    )
    parser.add_argument("--max-tokens", type=int, default=1024)
    parser.add_argument("--temperature", type=float, default=0.7)
    parser.add_argument("--enable-thinking", action="store_true")
    args, _unknown = parser.parse_known_args(argv)
    return args


def serve(args) -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        stream=sys.stderr,
    )
    cfg = EngineConfig(
        model_id=args.model,
        cache_gb=args.cache_gb,
        max_tokens=args.max_tokens,
        temperature=args.temperature,
        enable_thinking=args.enable_thinking,
    )
    model_path = resolve_model_path(cfg.model_id)
    engine = load_engine(cfg, model_path)
    app = build_app(engine, cfg.model_id)
    logger.info("Serving %s on %s:%d", cfg.model_id, args.host, args.port)
    uvicorn.run(app, host=args.host, port=args.port, log_level="warning")


def main(argv=None) -> int:
    args = _parse_args(argv)
    serve(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
