"""Hermes request observer for TokSpeed (local metrics only)."""

from contextlib import suppress
import fcntl
import hashlib
import json
import os
from pathlib import Path


def _label(value):
    return (
        value if isinstance(value, str) and 0 < len(value) <= 256
        and not any(ch.isspace() or not ch.isprintable() for ch in value)
        and "://" not in value else ""
    )


def _digest(value):
    if isinstance(value, str) and 0 < len(value) <= 1024:
        return hashlib.sha256(value.encode()).hexdigest()
    return ""


def _epoch(value):
    return type(value) in (int, float) and 946684800 <= value < 4102444800


def _tokens(value):
    return type(value) is int and 0 <= value <= 100_000_000


def _activity(root, event, *, session_id=None, api_request_id=None, started_at=None, **_ignored):
    session, request = _digest(session_id), _digest(api_request_id)
    if session and request and _epoch(started_at):
        row = dict(v=1, event=event, session=session, request=request, started_at=started_at)
        data = (json.dumps(row, separators=(",", ":")) + "\n").encode()
        _append(root, data, name="activity.jsonl", limit=256 * 1024)


def _observe(root, *, session_id=None, api_request_id=None, model=None, provider=None,
             started_at=None, ended_at=None, first_chunk_at=None, usage=None, **_ignored):
    # Do not inspect response, assistant_message, URL, headers or other payload fields.
    session, request = _digest(session_id), _digest(api_request_id)
    if not session or not request or not isinstance(usage, dict):
        return
    output, prompt = usage.get("output_tokens"), usage.get("prompt_tokens")
    if not _tokens(output) or output == 0 or not _tokens(prompt):
        return
    if not (_epoch(started_at) and _epoch(ended_at) and 0.001 <= ended_at - started_at <= 86400):
        return
    if not (_epoch(first_chunk_at) and started_at <= first_chunk_at < ended_at):
        first_chunk_at = None
    row = dict(v=1, session=session, request=request, model=_label(model),
               provider=_label(provider), started_at=started_at, ended_at=ended_at,
               first_chunk_at=first_chunk_at, input=prompt, output=output)
    data = (json.dumps(row, ensure_ascii=False, allow_nan=False, separators=(",", ":")) + "\n").encode()
    _append(root, data)


def _append(root, data, *, name="calls.jsonl", limit=2 * 1024 * 1024):
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    target = root / name
    flags = os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK
    lock = os.open(root / ".lock", flags, 0o600)
    try:
        # Best-effort observer: competing writers must never stall a completed request.
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if target.exists() and target.stat().st_size + len(data) > limit:
            target.replace(root / (name + ".1"))
        fd = os.open(target, flags | os.O_APPEND, 0o600)
        try:
            if os.write(fd, data) != len(data):
                # Do not concatenate the next complete record onto a partial write.
                os.write(fd, b"\n")
        finally:
            os.close(fd)
    finally:
        os.close(lock)


def register(ctx):
    from hermes_constants import get_hermes_home

    root = Path(get_hermes_home()) / "plugin-data" / "tokspeed-metrics"

    def pre_api_request(**event):
        with suppress(OSError, ValueError):
            _activity(root, "start", **event)

    def close_request(**event):
        with suppress(OSError, ValueError):
            _activity(root, "stop", **event)

    def post_api_request(**event):
        close_request(**event)
        with suppress(OSError, ValueError):
            _observe(root, **event)

    ctx.register_hook("pre_api_request", pre_api_request)
    ctx.register_hook("post_api_request", post_api_request)
    ctx.register_hook("api_request_error", close_request)
