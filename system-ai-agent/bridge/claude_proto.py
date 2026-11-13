"""Claude Code stream-json protocol: argv, stdin messages, permission filter, Normalizer.

Pure functions and a stateful Normalizer; no I/O here. Session adds `seq`/`session_id`.
"""

from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass

log = logging.getLogger(__name__)

ALLOWED_MODES = ("default", "acceptEdits", "plan", "bypassPermissions")
ALLOWED_EFFORTS = ('default', 'low', 'medium', 'high', 'xhigh', 'max')

DEFAULT_SYSTEM_PROMPT = (
    "You are running as the desktop system agent inside a Noctalia shell panel on Arch Linux "
    "with Hyprland. Reply in the user's language. Keep answers concise; use Markdown. You cannot "
    "answer interactive prompts: never run `sudo` or commands that wait for a password or TTY "
    "input; if root is required, show the exact command in a fenced code block and ask the user "
    "to run it. Prefer read-only diagnostics before changes, and explain each change before "
    "making it."
)

TOOL_RESULT_MAX_BYTES = 8192
TOOL_INPUT_MAX_BYTES = 4096
SUMMARY_MAX_CHARS = 160

_AUTH_MARKERS = ("Please run /login", "API Error: 401", "authentication_error")


# --------------------------------------------------------------------------- argv


UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


@dataclass
class LaunchOptions:
    claude_path: str
    cwd: str
    model: str = "default"
    permission_mode: str = "bypassPermissions"
    effort: str = "default"
    session_id: str | None = None
    resume_id: str | None = None
    extra_prompt: str = ""
    safe_mode: bool = False
    fork: bool = False  # with resume_id + session_id: branch the conversation into a new id
    resume_at: str | None = None  # fork only: keep the transcript up to this entry uuid (inclusive)


def build_argv(o: LaunchOptions) -> list[str]:
    if o.effort not in ALLOWED_EFFORTS:
        raise ValueError('invalid effort')
    if o.permission_mode not in ALLOWED_MODES:
        raise ValueError(f"permission mode not allowed: {o.permission_mode!r}")
    if o.fork and not (o.session_id and o.resume_id):
        raise ValueError("fork needs both session_id (new) and resume_id (source)")
    if o.resume_at and (not o.fork or not UUID_RE.match(o.resume_at)):
        raise ValueError("resume_at needs fork and a message uuid")
    if o.session_id and o.resume_id and not o.fork:
        raise ValueError("session_id and resume_id are mutually exclusive")
    model = o.model or "default"
    if model.startswith("-"):
        raise ValueError(f"invalid model: {model!r}")
    for value in (o.session_id, o.resume_id):
        if value and value.startswith("-"):
            raise ValueError(f"invalid session id: {value!r}")

    argv = [
        o.claude_path, "-p",
        "--input-format", "stream-json", "--output-format", "stream-json",
        "--verbose", "--include-partial-messages",
        "--permission-prompt-tool", "stdio",
        "--permission-mode", o.permission_mode,
    ]
    if model != "default":
        argv += ["--model", model]
    if o.effort != 'default':
        argv += ['--effort', o.effort]
    if o.fork:
        argv += ["--resume", o.resume_id, "--fork-session", "--session-id", o.session_id]
        if o.resume_at:
            argv += ["--resume-session-at", o.resume_at]
    elif o.session_id:
        argv += ["--session-id", o.session_id]
    elif o.resume_id:
        argv += ["--resume", o.resume_id]
    prompt = DEFAULT_SYSTEM_PROMPT
    extra = (o.extra_prompt or "").strip()
    if extra:
        prompt += "\n\n" + extra
    argv += [
        "--disallowedTools", "AskUserQuestion",
        "--append-system-prompt", prompt,
    ]
    if o.safe_mode:
        argv.append("--safe-mode")
    return argv


# --------------------------------------------------------------------------- stdin messages


def user_message(text: str, session_id: str, images: list[tuple[str, str]] | None = None) -> dict:
    """images: (media_type, base64 data) pairs, sent as image blocks before the text."""
    content: str | list = text
    if images:
        content = [{"type": "image", "source": {"type": "base64", "media_type": mt, "data": data}}
                   for mt, data in images]
        if text:
            content.append({"type": "text", "text": text})
    return {
        "type": "user",
        "message": {"role": "user", "content": content},
        "parent_tool_use_id": None,
        "session_id": session_id,
    }


def control_request(request_id: str, subtype: str, **fields) -> dict:
    return {"type": "control_request", "request_id": request_id,
            "request": {"subtype": subtype, **fields}}


def _control_success(request_id: str, response: dict) -> dict:
    return {"type": "control_response",
            "response": {"subtype": "success", "request_id": request_id, "response": response}}


def permission_allow(request_id: str, original_input, updated_permissions=None) -> dict:
    resp = {"behavior": "allow", "updatedInput": original_input}
    if updated_permissions:
        resp["updatedPermissions"] = updated_permissions
    return _control_success(request_id, resp)


def permission_deny(request_id: str, message: str, interrupt: bool = False) -> dict:
    resp = {"behavior": "deny", "message": message or "User denied"}
    if interrupt:
        resp["interrupt"] = True
    return _control_success(request_id, resp)


def control_error(request_id: str, error: str) -> dict:
    return {"type": "control_response",
            "response": {"subtype": "error", "request_id": request_id, "error": error}}


# --------------------------------------------------------------------------- permissions (spec §8.3)


def session_rules(tool_name: str, suggestions) -> list[dict]:
    """Keep only narrow allow-rules for this very tool, rewritten to destination=session."""
    out = []
    for s in suggestions or ():
        if not isinstance(s, dict) or s.get("type") != "addRules" or s.get("behavior") != "allow":
            continue
        rules = s.get("rules")
        if not isinstance(rules, list) or not rules:
            continue
        ok = all(
            isinstance(r, dict)
            and r.get("toolName") == tool_name
            and isinstance(r.get("ruleContent"), str)
            and r["ruleContent"].strip()
            for r in rules
        )
        if not ok:
            continue
        out.append({
            "type": "addRules",
            "rules": [{"toolName": r["toolName"], "ruleContent": r["ruleContent"]} for r in rules],
            "behavior": "allow",
            "destination": "session",
        })
    return out


def rule_preview(rules) -> str | None:
    parts = [f"{r['toolName']}({r['ruleContent']})" for s in rules or () for r in s.get("rules", ())]
    return ", ".join(parts) if parts else None


# --------------------------------------------------------------------------- text helpers


_CTRL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
_ANSI_CSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")


def _clean_text(s: str) -> str:
    """Make arbitrary (possibly binary-derived) text safe UTF-8 for JSON/UI."""
    if not isinstance(s, str):
        s = str(s)
    # lone surrogates -> U+FFFD
    s = s.encode("utf-8", "surrogatepass").decode("utf-8", "replace")
    s = _ANSI_CSI_RE.sub("", s)
    return _CTRL_RE.sub("�", s)


def _truncate_bytes(s: str, limit: int) -> tuple[str, bool]:
    b = s.encode("utf-8")
    if len(b) <= limit:
        return s, False
    return b[:limit].decode("utf-8", "ignore"), True


def _json_size(v) -> int:
    return len(json.dumps(v, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))


def _shrink(v, max_str: int):
    if isinstance(v, str):
        return v if len(v) <= max_str else v[:max_str] + "…"
    if isinstance(v, dict):
        return {k: _shrink(x, max_str) for k, x in v.items()}
    if isinstance(v, list):
        return [_shrink(x, max_str) for x in v]
    return v


def truncate_input(inp) -> tuple[object, bool]:
    """Fit a tool input into TOOL_INPUT_MAX_BYTES of JSON, keeping its shape where possible."""
    if inp is None:
        inp = {}
    try:
        if _json_size(inp) <= TOOL_INPUT_MAX_BYTES:
            return inp, False
    except (TypeError, ValueError):
        inp = str(inp)
    for max_str in (1024, 256, 64):
        small = _shrink(inp, max_str)
        try:
            if _json_size(small) <= TOOL_INPUT_MAX_BYTES:
                return small, True
        except (TypeError, ValueError):
            break
    text = _clean_text(json.dumps(inp, ensure_ascii=False, default=str))
    budget = TOOL_INPUT_MAX_BYTES - 16
    while True:
        preview, _ = _truncate_bytes(text, budget)
        result = {"_preview": preview}
        over = _json_size(result) - TOOL_INPUT_MAX_BYTES
        if over <= 0:
            return result, True
        budget = max(0, budget - over)  # JSON escaping inflated the size; shrink and re-measure


def tool_summary(name: str, input) -> str:
    key = {
        "Bash": "command",
        "Read": "file_path", "Edit": "file_path", "Write": "file_path", "NotebookEdit": "file_path",
        "WebFetch": "url",
        "WebSearch": "query",
    }.get(name)
    value = input.get(key) if key and isinstance(input, dict) else None
    if isinstance(value, str):
        s = value
    else:
        try:
            s = json.dumps(input, ensure_ascii=False, separators=(",", ":"), default=str)
        except (TypeError, ValueError):
            s = str(input)
    s = " ".join(s.split())
    if len(s) > SUMMARY_MAX_CHARS:
        s = s[: SUMMARY_MAX_CHARS - 1] + "…"
    return s


def is_auth_error(text) -> bool:
    if not text or not isinstance(text, str):
        return False
    return any(m in text for m in _AUTH_MARKERS)


def _tool_result_text(content) -> str:
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for c in content:
            if isinstance(c, dict):
                if c.get("type") == "text":
                    parts.append(str(c.get("text", "")))
                elif c.get("type") == "image":
                    parts.append("[image]")
                else:
                    parts.append(f"[{c.get('type', 'content')}]")
            else:
                parts.append(str(c))
        return "\n".join(parts)
    return json.dumps(content, ensure_ascii=False, default=str)


# --------------------------------------------------------------------------- Normalizer


class Normalizer:
    """Turns raw stream-json objects from claude stdout into UI events (spec §5.6), without seq."""

    def __init__(self):
        self._message_id: str | None = None
        self._blocks: dict[int, dict] = {}  # index -> {"kind", "text"} for current message
        self._streamed_messages: set[str] = set()
        self._fallback_counts: dict[str, int] = {}
        self._seen_tool_uses: set[str] = set()
        self._records: dict[str, int] = {}  # message id -> content blocks seen in assistant records

    def feed(self, raw) -> list[dict]:
        if not isinstance(raw, dict):
            return []
        t = raw.get("type")
        handler = {
            "system": self._system,
            "stream_event": self._stream_event,
            "assistant": self._assistant,
            "user": self._user,
            "rate_limit_event": self._rate_limit,
            "result": self._result,
            "control_request": self._control_request,
        }.get(t)
        if handler is None:
            log.debug("ignoring stdout type %r", t)
            return []
        try:
            return handler(raw)
        except (AttributeError, TypeError, KeyError, ValueError) as e:
            log.debug("malformed %r line ignored: %s", t, e)
            return []

    # -- system
    def _system(self, raw):
        if raw.get('subtype') == 'local_command_output':
            text = raw.get('content') or raw.get('output')
            if isinstance(text, str):
                return [{'type': 'assistant_text_done', 'block_id': 'local-' + str(raw.get('uuid')),
                         'text': _clean_text(text)}]
        if raw.get('subtype') == 'compact_boundary':
            return [{'type': 'assistant_text_done', 'block_id': 'compact-' + str(raw.get('uuid')),
                     'text': 'Context compacted.'}]
        if raw.get("subtype") != "init":
            log.debug("ignoring system subtype %r", raw.get("subtype"))
            return []
        return [{
            "type": "session_started",
            "session_id": raw.get("session_id"),
            "model": raw.get("model"),
            "cwd": raw.get("cwd"),
            "tools": list(raw.get("tools") or []),
            "permission_mode": raw.get("permissionMode"),
            "slash_commands": list(raw.get('slash_commands') or []),
        }]

    # -- stream_event
    def _stream_event(self, raw):
        ev = raw.get("event")
        if not isinstance(ev, dict):
            return []
        et = ev.get("type")
        if et == "message_start":
            msg = ev.get("message") or {}
            self._message_id = msg.get("id")
            self._blocks = {}
            if self._message_id:
                self._streamed_messages.add(self._message_id)
            return []
        if et == "content_block_start":
            cb = ev.get("content_block") or {}
            kind = cb.get("type")
            if kind in ("text", "thinking"):
                self._blocks[ev.get("index")] = {"kind": kind, "text": ""}
            return []
        if et == "content_block_delta":
            block = self._blocks.get(ev.get("index"))
            delta = ev.get("delta") or {}
            if block is None:
                return []
            dt = delta.get("type")
            if dt == "text_delta" and block["kind"] == "text":
                text = delta.get("text") or ""
                if not text:
                    return []
                block["text"] += text
                return [{"type": "assistant_text_delta", "block_id": self._block_id(ev.get("index")),
                         "text": text}]
            if dt == "thinking_delta" and block["kind"] == "thinking":
                block["text"] += delta.get("thinking") or ""
            return []
        if et == "content_block_stop":
            index = ev.get("index")
            block = self._blocks.pop(index, None)
            if block is None:
                return []
            etype = "assistant_text_done" if block["kind"] == "text" else "thinking"
            return [{"type": etype, "block_id": self._block_id(index), "text": block["text"]}]
        return []

    def _block_id(self, index) -> str:
        return f"{self._message_id}:{index}"

    # -- assistant (full message): tool calls; text only if it was not streamed
    def _assistant(self, raw):
        msg = raw.get("message")
        if not isinstance(msg, dict):
            return []
        mid = msg.get("id")
        streamed = mid is not None and mid in self._streamed_messages
        parent = raw.get("parent_tool_use_id")
        # Claude Code writes one record per content block, in block order, each with the uuid of
        # its transcript entry: the k-th record of a message is the streamed block with index k.
        uuid = raw.get("uuid") if isinstance(raw.get("uuid"), str) and UUID_RE.match(raw["uuid"]) else None
        content = msg.get("content") or []
        base = self._records.get(mid, 0) if mid is not None else 0
        if mid is not None and isinstance(content, list):
            self._records[mid] = base + len(content)
        out = []
        for position, c in enumerate(content):
            if not isinstance(c, dict):
                continue
            ct = c.get("type")
            if ct == "text" and streamed and uuid and parent is None:
                out.append({"type": "assistant_anchor", "block_id": f"{mid}:{base + position}", "uuid": uuid})
            if ct == "tool_use":
                tid = c.get("id")
                if tid in self._seen_tool_uses:
                    continue
                self._seen_tool_uses.add(tid)
                name = c.get("name") or ""
                inp = c.get("input")
                small, cut = truncate_input(inp)
                out.append({
                    "type": "tool_call",
                    "tool_use_id": tid,
                    "name": name,
                    "summary": tool_summary(name, inp),
                    "input": small,
                    "input_truncated": cut,
                    "parent": parent,
                })
            elif ct in ("text", "thinking") and not streamed:
                n = self._fallback_counts.get(mid, 0)
                self._fallback_counts[mid] = n + 1
                text = c.get("text") if ct == "text" else c.get("thinking")
                ev = {
                    "type": "assistant_text_done" if ct == "text" else "thinking",
                    "block_id": f"{mid}:{n}",
                    "text": text or "",
                }
                if ct == "text" and uuid and parent is None:
                    ev["uuid"] = uuid  # transcript entry: a branch point
                out.append(ev)
        return out

    # -- user: tool results
    def _user(self, raw):
        msg = raw.get("message")
        if not isinstance(msg, dict):
            return []
        content = msg.get("content")
        if not isinstance(content, list):
            return []
        out = []
        for c in content:
            if not isinstance(c, dict) or c.get("type") != "tool_result":
                continue
            text, cut = _truncate_bytes(_clean_text(_tool_result_text(c.get("content"))),
                                        TOOL_RESULT_MAX_BYTES)
            out.append({
                "type": "tool_result",
                "tool_use_id": c.get("tool_use_id"),
                "ok": not c.get("is_error", False),
                "text": text,
                "truncated": cut,
            })
        return out

    # -- rate limits
    def _rate_limit(self, raw):
        windows = (raw.get("rate_limit_info") or {}).get("unifiedWindows") or {}

        def util(name):
            w = windows.get(name)
            return w.get("utilization") if isinstance(w, dict) else None

        return [{"type": "rate_limit", "five_hour": util("five_hour"), "seven_day": util("seven_day")}]

    # -- result
    def _result(self, raw):
        subtype = raw.get("subtype")
        ok = subtype == "success" and not raw.get("is_error", False)
        ev = {
            "type": "turn_result",
            "ok": ok,
            "subtype": subtype,
            "duration_ms": raw.get("duration_ms"),
            "cost_usd": raw.get("total_cost_usd"),
            "usage": raw.get("usage") or {},
        }
        if not ok:
            errors = raw.get("errors")
            if isinstance(errors, list) and errors:
                err = "\n".join(str(e) for e in errors)
            else:
                err = raw.get("result") or subtype or "error"
            ev["error"], _ = _truncate_bytes(_clean_text(str(err)), TOOL_RESULT_MAX_BYTES)
        return [ev]

    # -- control_request (permissions)
    def _control_request(self, raw):
        req = raw.get("request")
        if not isinstance(req, dict) or req.get("subtype") != "can_use_tool":
            return []
        tool_name = req.get("tool_name") or ""
        inp = req.get("input")
        small, cut = truncate_input(inp)
        rules = session_rules(tool_name, req.get("permission_suggestions"))
        return [{
            "type": "permission_request",
            "request_id": raw.get("request_id"),
            "tool_use_id": req.get("tool_use_id"),
            "tool_name": tool_name,
            "display_name": req.get("display_name") or tool_name,
            "summary": tool_summary(tool_name, inp),
            "input": small,
            "input_truncated": cut,
            "description": req.get("description"),
            "blocked_path": req.get("blocked_path"),
            "allow_session_available": bool(rules),
            "session_rule_preview": rule_preview(rules),
        }]
