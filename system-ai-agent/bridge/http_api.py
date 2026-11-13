"""Loopback HTTP/1.1 API of the bridge (spec §00 "HTTP API v0.1", §5.3).

Deliberately tiny: one request per connection (`Connection: close`), request bodies only
with Content-Length (≤1 MB), JSON responses, and two long-lived NDJSON streams sent with
`Transfer-Encoding: chunked`, one JSON line per chunk.

Every request must carry `Authorization: Bearer <token>`, must not carry `Origin`, and its
`Host` must be exactly `127.0.0.1:<port>` (browser CSRF / DNS rebinding).
"""

from __future__ import annotations

import asyncio
import hmac
import json
import logging
import os
import shutil
from pathlib import Path
from dataclasses import dataclass
from typing import Callable
from urllib.parse import parse_qs, unquote, urlsplit

from . import claude_proto as cp
from .session import DECISIONS, Session
from .paths import PathIndex, MAX_ATTACHMENTS
from .images import ImageError, MAX_IMAGES

log = logging.getLogger(__name__)

VERSION = "0.1.0"
MAX_BODY_BYTES = 1024 * 1024
MAX_TEXT_CHARS = 100_000
MAX_FIELD_CHARS = 100_000  # extra_prompt, permission message, paths
MAX_MODEL_CHARS = 100
HEARTBEAT_SECONDS = 15.0
REQUEST_TIMEOUT = 10.0  # seconds to receive the head and the body of a request

_REASONS = {200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
            404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 413: "Payload Too Large",
            500: "Internal Server Error"}


# --------------------------------------------------------------------------- config


@dataclass
class BridgeConfig:
    claude_path: str | None
    cwd: str
    model: str = "default"
    permission_mode: str = "bypassPermissions"
    effort: str = "default"
    safe_mode: bool = False
    extra_prompt: str = ""


def resolve_claude_path(value: str | None) -> str | None:
    """Absolute path of an executable `claude`, or None.

    Empty/None: `shutil.which("claude")`, then `~/.local/bin/claude`. Otherwise the given
    value (`~` expanded; a bare name is looked up in PATH)."""
    def executable(p: str) -> str | None:
        return os.path.abspath(p) if os.path.isfile(p) and os.access(p, os.X_OK) else None

    if value:
        p = os.path.expanduser(value)
        if os.sep not in p:
            found = shutil.which(p)
            return os.path.abspath(found) if found else None
        return executable(p)
    found = shutil.which("claude")
    if found:
        return os.path.abspath(found)
    return executable(os.path.expanduser("~/.local/bin/claude"))


def make_opts_factory(cfg: BridgeConfig) -> Callable[[], cp.LaunchOptions]:
    """LaunchOptions from the *current* cfg: POST /v1/config applies to the next launch.

    claude not found -> FileNotFoundError, which Session turns into `error{kind:"spawn"}`."""
    def factory() -> cp.LaunchOptions:
        if not cfg.claude_path:
            raise FileNotFoundError("claude executable not found; set claude_path in the plugin settings")
        return cp.LaunchOptions(
            claude_path=cfg.claude_path, cwd=os.path.expanduser(cfg.cwd or "~"),
            model=cfg.model, permission_mode=cfg.permission_mode,
            effort=cfg.effort, extra_prompt=cfg.extra_prompt, safe_mode=cfg.safe_mode)
    return factory


# --------------------------------------------------------------------------- plumbing


class _HttpError(Exception):
    def __init__(self, status: int, error: str):
        super().__init__(error)
        self.status = status
        self.body = {"error": error}


class _Changes:
    """Version counter + wakeup for Session.on_change (fan-out to /v1/status streams)."""

    def __init__(self):
        self.version = 0
        self._event = asyncio.Event()

    def notify(self) -> None:
        self.version += 1
        event, self._event = self._event, asyncio.Event()
        event.set()

    async def wait(self, version: int) -> None:
        while self.version == version:
            await self._event.wait()


def _chain(first: Callable[[], None], second: Callable[[], None]) -> Callable[[], None]:
    def both() -> None:
        try:
            first()
        finally:
            second()
    return both


def _parse_json_object(body: bytes) -> dict:
    try:
        obj = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise _HttpError(400, "bad_json") from None
    if not isinstance(obj, dict):
        raise _HttpError(400, "bad_json")
    return obj


def _opt_str(obj: dict, key: str, limit: int = MAX_FIELD_CHARS, allow_none: bool = False):
    v = obj.get(key)
    if v is None and allow_none:
        return None
    if not isinstance(v, str) or len(v) > limit:
        raise _HttpError(400, "bad_json")
    return v


# --------------------------------------------------------------------------- server


def _list_field(obj: dict, key: str):
    """A JSON array field; an empty object (an empty Luau table) counts as []."""
    value = obj.get(key, [])
    return [] if value == {} else value


class _Api:
    def __init__(self, session: Session, cfg: BridgeConfig, token: str, heartbeat: float,
                 on_shutdown: Callable[[], None] | None):
        self.session = session
        self.cfg = cfg
        self._token = token.encode("ascii")
        self.heartbeat = heartbeat
        self.on_shutdown = on_shutdown
        self.port = 0
        self.changes = _Changes()
        self._tasks: set[asyncio.Task] = set()
        self.preferences = {}
        self._path_index = None
        self.preferences_path = session._data_dir / 'preferences.json'
        try:
            saved = json.loads(self.preferences_path.read_text())
            self.preferences = self._validate_preferences(saved)
        except (OSError, ValueError, TypeError, _HttpError):
            pass
        for key, value in self.preferences.items():
            setattr(cfg, key, value)

    @staticmethod
    def _validate_preferences(obj):
        if not isinstance(obj, dict) or not obj or set(obj) - {'model', 'effort', 'permission_mode'}:
            raise _HttpError(400, 'bad_preferences')
        for key, value in obj.items():
            if not isinstance(value, str):
                raise _HttpError(400, 'bad_preferences')
            if key == 'model' and (not value or len(value) > 100 or value.startswith('-') or
                                   any(c.isspace() or ord(c) < 32 for c in value)):
                raise _HttpError(400, 'bad_preferences')
            if key == 'effort' and value not in cp.ALLOWED_EFFORTS:
                raise _HttpError(400, 'bad_preferences')
            if key == 'permission_mode' and value not in cp.ALLOWED_MODES:
                raise _HttpError(400, 'bad_preferences')
        return dict(obj)

    def _preference_values(self):
        return {key: getattr(self.cfg, key) for key in ('model', 'effort', 'permission_mode')}

    def _paths_index(self):
        cwd=os.path.abspath(os.path.expanduser(self.session._selected_cwd or self.cfg.cwd or '~'))
        if self._path_index is None or str(self._path_index.cwd)!=cwd:
            self._path_index=PathIndex(cwd)
        return self._path_index

    async def _save_preferences(self, body):
        update = self._validate_preferences(_parse_json_object(body))
        async with self.session._lock:
            if self.session.state in ('running', 'waiting_permission') or self.session.pending:
                raise _HttpError(409, 'session_busy')
            saved = self.preferences | update
            path = self.preferences_path
            path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            temp = path.with_suffix('.tmp')
            fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, 'w') as file:
                os.fchmod(file.fileno(), 0o600)
                json.dump(saved, file)
            os.replace(temp, path)
            await self.session._close(self.session._p)
            self.session.commands = []
            for key, value in update.items():
                setattr(self.cfg, key, value)
            self.preferences = saved
            return {'ok': True, **self._preference_values()}

    # ------------------------------------------------------------------ connection

    async def handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            await self._handle(reader, writer)
        except (ConnectionError, asyncio.IncompleteReadError, asyncio.LimitOverrunError,
                TimeoutError):
            pass  # the client went away or stalled: nothing to answer
        except Exception:  # noqa: BLE001 - one bad request must never stop the server
            log.exception("HTTP handler failed")
            try:
                await self._send_json(writer, 500, {"error": "internal"})
            except Exception:  # noqa: BLE001
                pass
        finally:
            writer.close()

    async def _handle(self, reader, writer) -> None:
        try:
            method, target, headers = await asyncio.wait_for(self._read_head(reader), REQUEST_TIMEOUT)
            self._check_access(headers)
            body = await asyncio.wait_for(self._read_body(reader, headers), REQUEST_TIMEOUT)
            await self._route(method, target, body, reader, writer)
        except _HttpError as e:
            await self._send_json(writer, e.status, e.body)
            if e.status == 413:
                await self._discard(reader)

    @staticmethod
    async def _discard(reader, limit: int = 4 * MAX_BODY_BYTES) -> None:
        """Swallow an unread body so closing the socket does not RST away our answer."""
        writer_deadline = asyncio.get_running_loop().time() + 2.0
        while limit > 0:
            left = writer_deadline - asyncio.get_running_loop().time()
            if left <= 0:
                return
            chunk = await asyncio.wait_for(reader.read(65536), left)
            if not chunk:
                return
            limit -= len(chunk)

    async def _read_head(self, reader) -> tuple[str, str, dict[str, str]]:
        try:
            raw = await reader.readuntil(b"\r\n\r\n")
        except asyncio.LimitOverrunError:
            raise _HttpError(400, "bad_request") from None
        lines = raw.decode("latin-1").split("\r\n")
        parts = lines[0].split(" ")
        if len(parts) != 3 or not parts[2].startswith("HTTP/1.") or not parts[1].startswith("/"):
            raise _HttpError(400, "bad_request")
        headers: dict[str, str] = {}
        for line in lines[1:]:
            if not line:
                continue
            name, sep, value = line.partition(":")
            name = name.strip().lower()
            if not sep or not name or name in headers:
                raise _HttpError(400, "bad_request")  # duplicates would make checks ambiguous
            headers[name] = value.strip()
        return parts[0], parts[1], headers

    def _check_access(self, headers: dict[str, str]) -> None:
        if "origin" in headers or headers.get("host") != f"127.0.0.1:{self.port}":
            raise _HttpError(403, "forbidden")
        scheme, _, given = headers.get("authorization", "").partition(" ")
        if scheme != "Bearer" or not hmac.compare_digest(given.strip().encode("latin-1"), self._token):
            raise _HttpError(401, "unauthorized")

    async def _read_body(self, reader, headers: dict[str, str]) -> bytes:
        if "transfer-encoding" in headers:
            raise _HttpError(400, "bad_request")
        raw = headers.get("content-length", "0")
        if not raw.isdigit():
            raise _HttpError(400, "bad_request")
        length = int(raw)
        if length > MAX_BODY_BYTES:
            raise _HttpError(413, "too_large")
        return await reader.readexactly(length) if length else b""

    # ------------------------------------------------------------------ routes

    async def _route(self, method: str, target: str, body: bytes, reader, writer) -> None:
        url = urlsplit(target)
        path = url.path
        if path == '/v1/paths':
            self._need(method, 'GET')
            query = parse_qs(url.query, keep_blank_values=True)
            offset, limit = self._pagination(query, 4)
            await self.session.restore_history()
            index = self._paths_index()
            try:
                page = await asyncio.to_thread(index.suggest, query.get('query',[''])[0],
                    offset, limit, query.get('browse',['0'])[0]=='1')
            except ValueError:
                raise _HttpError(400,'invalid_path') from None
            except FileNotFoundError:
                raise _HttpError(404,'path_not_found') from None
            page['session_id'] = self.session.session_id
            return await self._send_json(writer,200,page)
        if path == '/v1/attachments/resolve':
            self._need(method,'POST')
            obj = _parse_json_object(body)
            await self.session.restore_history()
            index = self._paths_index()
            try:
                resolved = await asyncio.to_thread(index.resolve_file, obj.get('path'))
            except ValueError:
                raise _HttpError(400,'invalid_path') from None
            except FileNotFoundError:
                raise _HttpError(404,'path_not_found') from None
            return await self._send_json(writer,200,resolved)
        if path == '/v1/preferences':
            if method == 'GET':
                return await self._send_json(writer, 200, self._preference_values())
            self._need(method, 'POST')
            return await self._send_json(writer, 200, await self._save_preferences(body))
        if path == '/v1/sessions':
            self._need(method, 'GET')
            query = parse_qs(url.query)
            offset, limit = self._pagination(query, 30)
            page = await asyncio.to_thread(self.session.catalog.list_sessions,
                                           query.get('q', [''])[0][:1000], offset, limit)
            for item in page['sessions']:
                owned = self.session._p.proc.pid if self.session._p else None
                item['active'] = await asyncio.to_thread(self.session.catalog.is_active, item['id'], owned)
                item['selected'] = item['id'] == self.session.session_id
            return await self._send_json(writer, 200, page)
        if path == '/v1/history':
            self._need(method, 'GET')
            query = parse_qs(url.query)
            offset, limit = self._pagination(query, 100)
            try:
                page = await self.session.history_page(offset, limit)
            except (OSError, ValueError):
                raise _HttpError(404, 'session_not_found') from None
            return await self._send_json(writer, 200, page)
        if path == '/v1/sessions/select':
            self._need(method, 'POST')
            obj = _parse_json_object(body)
            confirm = obj.get('confirm_active', False)
            if not isinstance(confirm, bool):
                raise _HttpError(400, 'bad_json')
            try:
                await self.session.select_chat(_opt_str(obj, 'session_id', 36), confirm)
            except FileNotFoundError:
                raise _HttpError(404, 'session_not_found') from None
            except ValueError as e:
                raise _HttpError(409 if str(e) in ('session_busy', 'session_active_elsewhere') else 400,
                                 str(e)) from None
            return await self._send_json(writer, 200, {'ok': True, 'session_id': self.session.session_id})
        if path == '/v1/commands':
            self._need(method, 'GET')
            try:
                result = await self.session.prepare_commands()
            except ValueError as e:
                raise _HttpError(409 if str(e) == 'session_active_elsewhere' else 400, str(e)) from None
            return await self._send_json(writer, 200, result)
        if path.startswith("/v1/permissions/") and len(path) > len("/v1/permissions/"):
            self._need(method, "POST")
            rid = unquote(path[len("/v1/permissions/"):])
            return await self._send_json(writer, 200, await self._permission(rid, body))
        route = {
            "/v1/health": ("GET", self._health),
            "/v1/status": ("GET", None),
            "/v1/events": ("GET", None),
            "/v1/messages": ("POST", self._messages),
            "/v1/interrupt": ("POST", self._interrupt),
            "/v1/new": ("POST", self._new),
            "/v1/fork": ("POST", self._fork),
            "/v1/images/clipboard": ("POST", self._paste_image),
            "/v1/clipboard": ("POST", self._paste),
            "/v1/config": ("POST", self._config),
            "/v1/shutdown": ("POST", self._shutdown),
        }.get(path)
        if route is None:
            raise _HttpError(404, "not_found")
        self._need(method, route[0])
        if path == "/v1/status":
            return await self._status_stream(reader, writer)
        if path == "/v1/events":
            return await self._events_stream(self._since(url.query), reader, writer)
        await self._send_json(writer, 200, await route[1](body))

    @staticmethod
    def _pagination(query, default):
        try:
            off, lim = query.get('offset', ['0']), query.get('limit', [str(default)])
            if len(off) != 1 or len(lim) != 1:
                raise ValueError
            if not all(v.isascii() and v.isdigit() and len(v) <= 9 for v in [off[0], lim[0]]):
                raise ValueError
            offset, limit = int(off[0]), int(lim[0])
            if not 1 <= limit <= 200:
                raise ValueError
            return offset, limit
        except (ValueError, IndexError):
            raise _HttpError(400, 'bad_pagination') from None

    @staticmethod
    def _need(method: str, expected: str) -> None:
        if method != expected:
            raise _HttpError(405, "method_not_allowed")

    @staticmethod
    def _since(query: str) -> int:
        values = parse_qs(query).get("since", ["0"])
        if len(values) != 1 or not values[0].isdigit() or len(values[0]) > 18:
            raise _HttpError(400, "bad_request")
        return int(values[0])

    async def _health(self, _body: bytes) -> dict:
        return {"ok": True, "version": VERSION, "claude_path": self.cfg.claude_path}

    async def _messages(self, body: bytes) -> dict:
        obj = _parse_json_object(body)
        text = obj.get("text")
        # Noctalia's json.encode turns an empty Luau table into {}: treat it as an empty list.
        attachments = _list_field(obj, 'attachments')
        if not isinstance(attachments,list) or len(attachments)>MAX_ATTACHMENTS or any(
                not isinstance(p,str) or len(p)>4096 or not p or '\0' in p for p in attachments):
            raise _HttpError(400,'invalid_attachments')
        images = _list_field(obj, 'images')
        if not isinstance(images, list) or len(images) > MAX_IMAGES or any(
                not isinstance(i, str) or len(i) > 64 for i in images):
            raise _HttpError(400, 'invalid_images')
        if not isinstance(text, str) or (not text.strip() and not attachments and not images):
            raise _HttpError(400, "bad_json")
        if len(text) > MAX_TEXT_CHARS:
            raise _HttpError(400, "text_too_long")
        try:
            await self.session.send(text, attachments, images, default_cwd=self.cfg.cwd)
        except FileNotFoundError:
            raise _HttpError(404,'path_not_found') from None
        except ImageError as e:
            raise _HttpError(404 if str(e) == 'image_not_found' else 400, str(e)) from None
        except ValueError as e:
            raise _HttpError(409 if str(e) == 'session_busy' else 400, str(e)) from None
        return {"ok": True}

    async def _interrupt(self, _body: bytes) -> dict:
        await self.session.interrupt()
        return {"ok": True}

    async def _permission(self, request_id: str, body: bytes) -> dict:
        obj = _parse_json_object(body)
        decision = obj.get("decision")
        if decision not in DECISIONS:
            raise _HttpError(400, "bad_json")
        message = _opt_str(obj, "message", allow_none=True)
        try:
            await self.session.resolve_permission(request_id, decision, message)
        except KeyError:
            raise _HttpError(404, "not_found") from None
        return {"ok": True}

    async def _fork(self, body: bytes) -> dict:
        at = _parse_json_object(body).get('at') if body else None
        try:
            await self.session.fork(at)
        except ValueError as e:
            code = str(e)
            raise _HttpError({'session_busy': 409, 'message_not_found': 404}.get(code, 400), code) from None
        return {"ok": True}

    async def _paste_image(self, _body: bytes) -> dict:
        """Stores the clipboard image. No upload: the bridge reads the clipboard itself."""
        try:
            return await asyncio.to_thread(self.session.images.paste_clipboard)
        except ImageError as e:
            code = str(e)
            raise _HttpError({'no_image': 404, 'clipboard_unavailable': 503}.get(code, 400), code) from None

    async def _paste(self, _body: bytes) -> dict:
        """Ctrl+V: the clipboard image (stored) or its text, whichever it holds."""
        try:
            return await asyncio.to_thread(self.session.images.paste)
        except ImageError as e:
            code = str(e)
            raise _HttpError({'clipboard_empty': 404, 'clipboard_unavailable': 503}.get(code, 400), code) from None

    async def _new(self, _body: bytes) -> dict:
        try:
            await self.session.new_chat()
        except ValueError as e:
            raise _HttpError(409, str(e)) from None
        return {"ok": True}

    async def _config(self, body: bytes) -> dict:
        obj = _parse_json_object(body)
        # validate everything first: a rejected request changes nothing
        if "permission_mode" in obj and obj["permission_mode"] not in cp.ALLOWED_MODES:
            raise _HttpError(400, "bad_mode")
        update: dict = {}
        if "claude_path" in obj:
            update["claude_path"] = resolve_claude_path(_opt_str(obj, "claude_path", allow_none=True))
        if "cwd" in obj:
            update["cwd"] = _opt_str(obj, "cwd") or "~"
        if "model" in obj:
            model = _opt_str(obj, "model", MAX_MODEL_CHARS) or "default"
            if model.startswith("-") or any(c.isspace() for c in model):
                raise _HttpError(400, "bad_json")
            update["model"] = model
        if 'effort' in obj:
            if obj['effort'] not in cp.ALLOWED_EFFORTS:
                raise _HttpError(400, 'bad_effort')
            update['effort'] = obj['effort']
        if "permission_mode" in obj:
            update["permission_mode"] = obj["permission_mode"]
        if "safe_mode" in obj:
            if not isinstance(obj["safe_mode"], bool):
                raise _HttpError(400, "bad_json")
            update["safe_mode"] = obj["safe_mode"]
        if "extra_prompt" in obj:
            update["extra_prompt"] = _opt_str(obj, "extra_prompt")
        for key, value in (update | self.preferences).items():
            setattr(self.cfg, key, value)
        return {"ok": True}

    async def _shutdown(self, _body: bytes) -> dict:
        if self.on_shutdown is not None:
            asyncio.get_running_loop().call_soon(self.on_shutdown)
        else:
            task = asyncio.create_task(self.session.shutdown())
            self._tasks.add(task)
            task.add_done_callback(self._tasks.discard)
        return {"ok": True}

    # ------------------------------------------------------------------ responses

    @staticmethod
    async def _send_json(writer, status: int, obj: dict) -> None:
        body = json.dumps(obj).encode("ascii")
        head = (f"HTTP/1.1 {status} {_REASONS.get(status, 'Error')}\r\n"
                "Content-Type: application/json\r\n"
                f"Content-Length: {len(body)}\r\n"
                "Cache-Control: no-store\r\n"
                "Connection: close\r\n\r\n")
        writer.write(head.encode("ascii") + body)
        await writer.drain()

    @staticmethod
    async def _start_stream(writer) -> None:
        writer.write(b"HTTP/1.1 200 OK\r\n"
                     b"Content-Type: application/x-ndjson\r\n"
                     b"Transfer-Encoding: chunked\r\n"
                     b"Cache-Control: no-store\r\n"
                     b"Connection: close\r\n\r\n")
        await writer.drain()

    @staticmethod
    async def _send_line(writer, obj: dict) -> None:
        data = (json.dumps(obj) + "\n").encode("ascii")
        writer.write(b"%X\r\n%s\r\n" % (len(data), data))
        await writer.drain()

    async def _wait(self, waiter, disconnected: asyncio.Future) -> bool:
        """Wait for `waiter` (awaitable) for up to one heartbeat interval.
        True: it completed; False: heartbeat due. Raises ConnectionError if the client left."""
        task = asyncio.ensure_future(waiter)
        try:
            done, _ = await asyncio.wait({task, disconnected}, timeout=self.heartbeat,
                                         return_when=asyncio.FIRST_COMPLETED)
        finally:
            task.cancel()
        if disconnected in done:
            raise ConnectionError("client disconnected")
        return task in done

    @staticmethod
    def _watch_disconnect(reader) -> asyncio.Future:
        # nothing more is expected from the client; EOF (or junk) means it is gone
        return asyncio.ensure_future(reader.read(1))

    async def _status_stream(self, reader, writer) -> None:
        await self._start_stream(writer)
        disconnected = self._watch_disconnect(reader)
        try:
            while True:
                version = self.changes.version
                s = self.session
                await self._send_line(writer, {"type": "status", "state": s.state,
                                               "pending": len(s.pending), "title": s.title,
                                               "completion": s.completion})
                while not await self._wait(self.changes.wait(version), disconnected):
                    await self._send_line(writer, {"type": "heartbeat"})
        finally:
            disconnected.cancel()

    async def _events_stream(self, since: int, reader, writer) -> None:
        await self.session.restore_history()
        log_ = self.session.log
        await self._start_stream(writer)
        disconnected = self._watch_disconnect(reader)
        cursor = since
        try:
            while True:
                reset, events = log_.since(cursor)
                if reset and not (events and events[0].get("type") == "reset"):
                    # Session's own reset (new chat) is forwarded as is; otherwise synthesize one
                    first = events[0]["seq"] - 1 if events else log_.last_seq
                    await self._send_line(writer, {"type": "reset", "seq": first})
                    cursor = first
                for ev in events:
                    await self._send_line(writer, ev)
                    cursor = ev["seq"]
                while not await self._wait(log_.wait_new(cursor), disconnected):
                    await self._send_line(writer, {"type": "heartbeat", "seq": cursor})
        finally:
            disconnected.cancel()


async def start_server(session: Session, cfg: BridgeConfig, token: str, host: str = "127.0.0.1",
                       port: int = 0, *, heartbeat: float = HEARTBEAT_SECONDS,
                       on_shutdown: Callable[[], None] | None = None) -> tuple[asyncio.Server, int]:
    """Serve the v1 API. `on_shutdown` is called after answering POST /v1/shutdown (default:
    session.shutdown()). The server hooks into session's on_change to push /v1/status."""
    api = _Api(session, cfg, token, heartbeat, on_shutdown)
    session._on_change = _chain(session._on_change, api.changes.notify)
    server = await asyncio.start_server(api.handle, host, port)
    api.port = server.sockets[0].getsockname()[1]
    return server, api.port
