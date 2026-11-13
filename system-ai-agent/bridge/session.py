"""EventLog and Session: the bridge's single `claude` process (spec §00, §5.5, §7.2–7.3, §8.3–8.4).

Session owns one lazily started `claude -p` process, turns its stdout into UI events
(claude_proto.Normalizer), keeps them in an EventLog with a monotonic `seq`, and answers
permission requests only when the user decides. Nothing here is ever auto-allowed.
"""

from __future__ import annotations

import asyncio
import ctypes
import dataclasses
import json
import logging
import os
import signal
import uuid
from collections import deque
from pathlib import Path
from typing import Callable

from . import claude_proto as cp
from .history import SessionCatalog
from .paths import reference_message
from .images import ImageStore

log = logging.getLogger(__name__)

STREAM_LIMIT = 16 * 1024 * 1024
STDERR_TAIL_BYTES = 4096
TITLE_MAX_CHARS = 60
HISTORY_TAIL = 200  # events shown when a chat is opened; older ones come page by page
LAST_SESSION_FILE = "last_session.json"
DECISIONS = ("allow_once", "allow_session", "deny")
STATES = ("idle", "running", "waiting_permission", "error")

# --------------------------------------------------------------------------- pdeathsig

_PR_SET_PDEATHSIG = 1
_SIGTERM = int(signal.SIGTERM)
try:  # resolved in the parent: nothing is loaded between fork and exec
    _prctl = ctypes.CDLL(None, use_errno=True).prctl
except (OSError, AttributeError):  # pragma: no cover - non-glibc
    _prctl = None


def _set_pdeathsig() -> None:
    """preexec_fn: the child gets SIGTERM if the bridge dies."""
    if _prctl is not None:
        _prctl(_PR_SET_PDEATHSIG, _SIGTERM, 0, 0, 0)


# --------------------------------------------------------------------------- EventLog


class EventLog:
    """Ring buffer of events with a monotonic `seq` (starting at 1, never reused)."""

    def __init__(self, maxlen: int = 5000):
        self._buf: deque[dict] = deque(maxlen=maxlen)
        self.last_seq = 0
        self._min_ok = 0  # smallest client seq that can continue without a reset
        self._waiter = asyncio.Event()

    def append(self, ev: dict) -> int:
        self.last_seq += 1
        ev["seq"] = self.last_seq
        if self._buf.maxlen is not None and len(self._buf) == self._buf.maxlen and self._buf:
            self._min_ok = self._buf[0]["seq"]  # client must have seen the evicted event
        self._buf.append(ev)
        waiter, self._waiter = self._waiter, asyncio.Event()
        waiter.set()
        return self.last_seq

    def since(self, seq: int) -> tuple[bool, list[dict]]:
        """Events with seq > `seq`. reset=True when some of them are gone (or `seq` is from
        another bridge run): the client must drop its state and take all returned events."""
        reset = seq < self._min_ok or seq > self.last_seq
        if reset:
            return True, list(self._buf)
        return False, [e for e in self._buf if e["seq"] > seq]

    async def wait_new(self, seq: int) -> None:
        """Return as soon as last_seq != seq (new events, or `seq` is stale)."""
        while self.last_seq == seq:
            await self._waiter.wait()

    def clear(self) -> None:
        self._buf.clear()
        self._min_ok = self.last_seq + 1  # everyone who saw old events resets


# --------------------------------------------------------------------------- Session


class _Proc:
    """One running `claude` process and its bookkeeping."""

    def __init__(self, proc: asyncio.subprocess.Process, wire_id: str):
        self.proc = proc
        self.wire_id = wire_id  # session id put into stdin user messages
        self.stderr = bytearray()
        self.dead = False  # stdout EOF or exit seen
        self.expected_exit = False  # we closed it (new_chat / shutdown)
        self.forced = False  # killed by the interrupt watchdog
        self.resumed = False  # launched with --resume
        self.fork_from: str | None = None  # launched with --resume <this> --fork-session
        self.started = False  # session_started seen
        self.initialize_id = None
        self.initialized = asyncio.Event()
        self.task: asyncio.Task | None = None  # _run(): completes after exit handling


class Session:
    INTERRUPT_GRACE = 10.0  # seconds without `result` after interrupt -> SIGINT, then SIGTERM
    CLOSE_GRACE = 5.0  # seconds after stdin EOF -> SIGTERM
    COALESCE_SECONDS = 0.05

    def __init__(self, opts_factory: Callable[[], cp.LaunchOptions], *,
                 on_change: Callable[[], None], data_dir: Path):
        self._opts_factory = opts_factory
        self._on_change = on_change
        self._data_dir = Path(data_dir)
        self.state = "idle"
        self.title: str | None = None
        self.pending: dict[str, dict] = {}
        self.log = EventLog()
        self.session_id: str | None = self._load_last_session()
        self._saved_id = self.session_id
        self._norm = cp.Normalizer()
        self._p: _Proc | None = None
        self._lock = asyncio.Lock()
        self._req_counter = 0
        self._deltas: dict[str, list[str]] = {}
        self._flush_handle: asyncio.TimerHandle | None = None
        self._turn_done = asyncio.Event()
        self._watchdog: asyncio.Task | None = None
        self._interrupted = False  # the user pressed Stop during the current turn
        self.catalog = SessionCatalog()
        self.commands = []
        self._selected_cwd = None
        self._history_restored = False
        self._turn_has_output = False
        self._needs_resume_validation = bool(self.session_id)
        self.completion = None
        self._completion_id = 0
        self._fork_from: str | None = None  # next spawn branches this session into a new id
        self._fork_at: str | None = None  # ...keeping it only up to this assistant entry uuid
        self.images = ImageStore(self._data_dir / "images")
        self.images.prune()

    # ------------------------------------------------------------------ public API

    async def send(self, text: str, attachments=None, images=None, *, default_cwd=None) -> None:
        if text.startswith('/') and not images:
            name = text.split(None, 1)[0][1:]
            if name in ('new', 'clear'):
                await self.new_chat()
                return
            if name in ('fork', 'branch'):
                await self.fork()
                return
            if name == 'resume':
                arg = text.split(None, 1)
                if len(arg) == 2:
                    await self.select_chat(arg[1].strip())
                    return
                raise ValueError('select_chat')
            result = await self.prepare_commands()
            if not result['ready']:
                raise ValueError('commands_not_ready')
            if name not in {c['name'] for c in self.commands}:
                raise ValueError('unknown_command')
        async with self._lock:
            await self._restore_history_locked()
            await self._validate_startup_resume()
            if attachments:
                cwd = self._selected_cwd or default_cwd or self._opts_factory().cwd or '~'
                text = await asyncio.to_thread(reference_message, text, attachments, cwd)
            loaded = [await asyncio.to_thread(self.images.load, i) for i in images or []]
            if self.title is None:
                self.title = (text or "[image]")[:TITLE_MAX_CHARS]
                self._changed()
            ev = {"type": "user_message", "text": text}
            if loaded:
                ev["images"] = [path for _, _, path in loaded]
            self._emit(ev)
            self._interrupted = False
            self._turn_has_output = False
            p = await self._ensure_process()
            if p is None:
                self._record_completion('error')
                return
            self._set_state("waiting_permission" if self.pending else "running")
            await self._write(p, cp.user_message(text, p.wire_id,
                                                 [(mt, data) for mt, data, _ in loaded] or None))

    async def interrupt(self) -> None:
        async with self._lock:
            p = self._live()
            if p is not None and self.state in ("running", "waiting_permission"):
                self._interrupted = True
            await self._deny_all(p, "Interrupted by user", interrupt=True)
            if p is None or self.state != "running":
                return
            # a watchdog from an earlier interrupt would wait on a stale Event: replace it
            if self._watchdog is not None:
                self._watchdog.cancel()
            self._turn_done = asyncio.Event()
            await self._write(p, cp.control_request(self._next_req_id(), "interrupt"))
            self._watchdog = asyncio.create_task(self._interrupt_watchdog(p, self._turn_done))

    async def resolve_permission(self, request_id: str, decision: str, message: str | None = None) -> None:
        async with self._lock:
            entry = self.pending[request_id]  # KeyError -> 404 in the HTTP layer
            if decision not in DECISIONS:
                raise ValueError(f"unknown decision: {decision!r}")
            del self.pending[request_id]
            if decision == "deny":
                reply = cp.permission_deny(request_id, message or "User denied")
            else:
                rules = []
                if decision == "allow_session":
                    rules = cp.session_rules(entry["tool_name"], entry["permission_suggestions"])
                    if not rules:
                        decision = "allow_once"
                reply = cp.permission_allow(request_id, entry["input"], rules or None)
            if not await self._write(self._live(), reply):
                decision = "cancelled"  # the process is gone; nothing was delivered
            self._emit({"type": "permission_resolved", "request_id": request_id, "decision": decision})
            self._after_pending_change()

    async def new_chat(self) -> None:
        async with self._lock:
            if self.state in ('running', 'waiting_permission'):
                raise ValueError('session_busy')
            p = self._live()
            await self._deny_all(p, "User started a new chat")
            await self._close(self._p)
            self._flush_deltas()
            self.session_id = None
            self._saved_id = None
            self._fork_from = None
            self._fork_at = None
            self.title = None
            self._selected_cwd = None
            self.commands = []
            self._history_restored = True
            self._needs_resume_validation = False
            self._norm = cp.Normalizer()
            self.log.clear()
            self._append({"type": "reset"})
            self._delete_last_session()
            self.state = "idle"
            self._changed()

    async def fork(self, at: str | None = None) -> None:
        """Branch the conversation: the next message continues a copy under a new id.

        at: uuid of an assistant text entry; the branch keeps the conversation up to and
        including it (the feed is cut there). Without it the whole conversation is kept.
        The original stays intact in the chat list. Nothing is spawned here.
        """
        if at is not None and (not isinstance(at, str) or not cp.UUID_RE.match(at)):
            raise ValueError('message_not_found')
        async with self._lock:
            if self.state in ('running', 'waiting_permission'):
                raise ValueError('session_busy')
            await self._restore_history_locked()
            source = self._fork_from or self.session_id
            if not source:
                raise ValueError('nothing_to_fork')
            kept = None
            if at is not None:
                try:
                    kept = await asyncio.to_thread(self._branch_events, source, at)
                except OSError:
                    raise ValueError('message_not_found') from None
            await self._close(self._p)
            self._flush_deltas()
            self._fork_from = source
            if at is not None:
                self._fork_at = at
            self.session_id = None
            self._saved_id = None
            self._needs_resume_validation = False
            self._norm = cp.Normalizer()
            self._interrupted = False
            self.state = 'idle'
            if kept is not None:
                tail = kept[-HISTORY_TAIL:]
                self.log.clear()
                self._append({'type': 'reset', 'history_offset': len(kept) - len(tail),
                              'history_total': len(kept)})
                for ev in tail:
                    self._append(dict(ev))
            self._emit({'type': 'forked', 'from': source, 'title': self.title, 'at': at})
            self._changed()

    def _branch_events(self, source: str, at: str | None) -> list[dict]:
        """History of `source`, cut after the assistant entry `at` (blocking: run in a thread)."""
        events = self.catalog.events(source, 0, 10 ** 9)['events']
        if at is None:
            return events
        for i, ev in enumerate(events):
            if ev.get('type') == 'assistant_text_done' and ev.get('uuid') == at:
                return events[:i + 1]
        raise ValueError('message_not_found')

    async def history_page(self, offset: int, limit: int) -> dict:
        """A page of the current chat's history; for a pending branch, the source cut at the fork."""
        async with self._lock:
            await self._restore_history_locked()
            source, at, sid = self._fork_from, self._fork_at, self.session_id
        if source:
            events = await asyncio.to_thread(self._branch_events, source, at)
            if offset < 0:
                offset = max(0, len(events) - limit)
            return dict(events=events[offset:offset + limit], total=len(events), offset=offset,
                        limit=limit, session_id=None)
        if not sid:
            return dict(events=[], total=0, offset=offset, limit=limit, session_id=None)
        page = await asyncio.to_thread(self.catalog.events, sid, offset, limit)
        page['session_id'] = sid
        return page

    async def restore_history(self):
        async with self._lock:
            await self._restore_history_locked()

    async def _restore_history_locked(self):
        if self._history_restored:
            return
        self._history_restored = True
        if not self.session_id:
            return
        try:
            info = await asyncio.to_thread(self.catalog.get_session, self.session_id)
            page = await asyncio.to_thread(self.catalog.events, self.session_id, -1, HISTORY_TAIL)
        except (OSError, ValueError):
            return  # keep the resume id: a temporarily missing history is not deletion
        self._selected_cwd = info['cwd'] or None
        self.title = info['title']
        self._publish_history(page)

    def _publish_history(self, page):
        self.log.clear()
        self._append({'type': 'reset', 'history_offset': page['offset'], 'history_total': page['total']})
        for ev in page['events']:
            self._append(dict(ev))
        self._changed()

    async def select_chat(self, sid, confirm_active=False):
        async with self._lock:
            if self.state in ('running', 'waiting_permission'):
                raise ValueError('session_busy')
            info = await asyncio.to_thread(self.catalog.get_session, sid)
            if not info['cwd'] or not os.path.isdir(info['cwd']):
                raise ValueError('missing_cwd')
            owned_pid = self._p.proc.pid if self._p else None
            if not confirm_active and await asyncio.to_thread(self.catalog.is_active, sid, owned_pid):
                raise ValueError('session_active_elsewhere')
            page = await asyncio.to_thread(self.catalog.events, sid, -1, HISTORY_TAIL)
            await self._close(self._p)
            self._flush_deltas()
            self.session_id = sid
            self._fork_from = None
            self._fork_at = None
            self._selected_cwd = info['cwd']
            self.title = info['title']
            self.commands = []
            self._norm = cp.Normalizer()
            self._interrupted = False
            self._history_restored = True
            self._needs_resume_validation = False
            self._save_last_session(sid)
            self.state = 'idle'
            self._publish_history(page)

    async def prepare_commands(self):
        async with self._lock:
            await self._restore_history_locked()
            p = await self._ensure_process()
            if p is None:
                return {'commands': self._command_list(), 'ready': False}
            try:
                await asyncio.wait_for(p.initialized.wait(), 12)
            except TimeoutError:
                return {'commands': self._command_list(), 'ready': False}
            return {'commands': self._command_list(), 'ready': True}

    async def _validate_startup_resume(self):
        if not self._needs_resume_validation or not self.session_id:
            return
        try:
            info = await asyncio.to_thread(self.catalog.get_session, self.session_id)
        except (OSError, ValueError):
            raise ValueError('session_not_found') from None
        if not info['cwd'] or not os.path.isdir(info['cwd']):
            raise ValueError('missing_cwd')
        if await asyncio.to_thread(self.catalog.is_active, self.session_id):
            raise ValueError('session_active_elsewhere')
        self._selected_cwd = info['cwd']
        self._needs_resume_validation = False

    def _command_list(self):
        local = [{'name': 'new', 'description': 'New chat'},
                 {'name': 'clear', 'description': 'New chat'},
                 {'name': 'resume', 'description': 'Choose a local conversation'},
                 {'name': 'fork', 'description': 'Branch this conversation into a new chat'}]
        return local + [c for c in self.commands if c['name'] not in ('new', 'clear', 'resume', 'fork')]

    def _set_commands(self, values, merge=False):
        by_name = {c['name']: c for c in self.commands} if merge else {}
        for value in values or []:
            obj = {'name': value, 'description': ''} if isinstance(value, str) else value
            if not isinstance(obj, dict):
                continue
            name = obj.get('name')
            if not isinstance(name, str) or not name or any(c.isspace() for c in name):
                continue
            for n in [name, *(obj.get('aliases') or [])]:
                if isinstance(n, str) and n and not any(c.isspace() for c in n):
                    by_name[n] = {'name': n, 'description': str(obj.get('description') or '')[:1000]}
        self.commands = sorted(by_name.values(), key=lambda c: c['name'])

    async def shutdown(self) -> None:
        async with self._lock:
            await self._deny_all(self._live(), "Bridge is shutting down")
            await self._close(self._p)
            self._flush_deltas()
            if self._watchdog is not None:
                self._watchdog.cancel()

    # ------------------------------------------------------------------ process lifecycle

    def _live(self) -> _Proc | None:
        p = self._p
        return p if p is not None and not p.dead else None

    async def _ensure_process(self) -> _Proc | None:
        await self._validate_startup_resume()
        p = self._p
        if p is not None and p.dead:
            await asyncio.shield(p.task)  # let the crash be reported before respawning
            p = self._p
        if p is not None:
            return p
        return await self._spawn()

    async def _spawn(self) -> _Proc | None:
        try:
            opts = self._opts_factory()
            if self._selected_cwd:
                opts = dataclasses.replace(opts, cwd=self._selected_cwd)
            if self._fork_from:
                wire_id = str(uuid.uuid4())
                opts = dataclasses.replace(opts, session_id=wire_id, resume_id=self._fork_from, fork=True,
                                           resume_at=self._fork_at)
            elif self.session_id:
                wire_id = self.session_id
                opts = dataclasses.replace(opts, session_id=None, resume_id=wire_id)
            else:
                wire_id = str(uuid.uuid4())
                opts = dataclasses.replace(opts, session_id=wire_id, resume_id=None)
            argv = cp.build_argv(opts)
            cwd = os.path.expanduser(opts.cwd or "~")
            if not os.path.isdir(cwd):
                raise NotADirectoryError(f"working directory does not exist: {cwd}")
            proc = await asyncio.create_subprocess_exec(
                *argv, cwd=cwd, env=self._child_env(),
                stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                preexec_fn=_set_pdeathsig, limit=STREAM_LIMIT)
        except Exception as e:  # noqa: BLE001 - any spawn failure becomes an event, never a crash
            if not isinstance(e, (OSError, ValueError)):
                log.exception("unexpected error while starting claude")
            self._emit({"type": "error", "kind": "spawn", "message": f"Cannot start claude: {e}"})
            self._set_state("error")
            return None
        # Freeze the logical chat's folder. Config changes apply to a new chat,
        # not to references (or a resumed process) in this existing conversation.
        self._selected_cwd = cwd
        p = _Proc(proc, wire_id)
        p.resumed = opts.resume_id is not None
        p.fork_from = opts.resume_id if opts.fork else None
        self._p = p
        self.commands = []
        self._norm = cp.Normalizer()
        p.task = asyncio.create_task(self._run(p))
        p.initialize_id = self._next_req_id()
        await self._write(p, cp.control_request(p.initialize_id, "initialize", hooks=None))
        return p

    @staticmethod
    def _child_env() -> dict[str, str]:
        env = dict(os.environ)
        env["CLAUDE_AGENT_BRIDGE"] = "1"
        local_bin = os.path.expanduser("~/.local/bin")
        parts = [x for x in env.get("PATH", "").split(os.pathsep) if x]
        if local_bin not in parts:
            parts.append(local_bin)
        env["PATH"] = os.pathsep.join(parts)
        return env

    async def _run(self, p: _Proc) -> None:
        reader = asyncio.create_task(self._read_stdout(p))
        stderr = asyncio.create_task(self._read_stderr(p))
        try:
            rc = await p.proc.wait()
            p.dead = True
            # a grandchild may still hold the pipes: give them a moment, then stop reading
            done, _ = await asyncio.wait({reader, stderr}, timeout=2.0)
            for t in (reader, stderr):
                if t not in done:
                    t.cancel()
            await asyncio.gather(reader, stderr, return_exceptions=True)
        except asyncio.CancelledError:
            reader.cancel()
            stderr.cancel()
            raise
        finally:
            p.dead = True
            if self._p is p:
                self._p = None
        self._on_exit(p, rc)

    async def _read_stdout(self, p: _Proc) -> None:
        stream = p.proc.stdout
        while True:
            try:
                line = await stream.readline()
            except ValueError:  # line over STREAM_LIMIT; the reader already dropped it
                log.warning("oversized line from claude skipped")
                continue
            if not line:
                p.dead = True
                return
            try:
                self._handle_line(p, line)
            except Exception:  # noqa: BLE001 - one bad line must not stop the session
                log.exception("failed to handle a claude stdout line")

    async def _read_stderr(self, p: _Proc) -> None:
        while chunk := await p.proc.stderr.read(4096):
            p.stderr += chunk
            del p.stderr[:-STDERR_TAIL_BYTES]

    def _on_exit(self, p: _Proc, rc: int) -> None:
        if p.expected_exit:
            return
        self._flush_deltas()
        mid_turn = self.state in ("running", "waiting_permission")
        self._cancel_pending("cancelled")
        tail = p.stderr.decode("utf-8", "replace").strip()
        if rc == 0 and not p.forced and not cp.is_auth_error(tail):
            # A clean exit (real claude exits 0 on SIGINT) is not a crash: end the turn quietly;
            # the next message starts it again with --resume.
            log.warning("claude exited with code 0; the next message resumes the session")
            if mid_turn:
                self._emit({"type": "turn_result", "ok": False, "subtype": "interrupted",
                            "duration_ms": None, "cost_usd": None, "usage": {}})
            self._interrupted = False
            self._set_state("idle")
            return
        if p.forced:
            if not self._turn_done.is_set():
                self._emit({"type": "turn_result", "ok": False, "subtype": "interrupted",
                            "duration_ms": None, "cost_usd": None, "usage": {},
                            "error": "claude did not stop after interrupt; the process was stopped"})
            self._set_state("idle")
            return
        kind = "auth" if cp.is_auth_error(tail) else "crash"
        message = f"claude exited unexpectedly (code {rc})"
        if tail:
            message += "\n" + tail
        if p.fork_from and not p.started and self._fork_from == p.fork_from:
            # the branch never started (source transcript gone?): stay in the source chat
            log.warning("forking the conversation failed; staying in the original chat")
            self.session_id = p.fork_from
            self._fork_from = None
            self._fork_at = None
            message += "\nCould not branch the conversation; you are still in the original chat."
        elif p.resumed and not p.started and self.session_id == p.wire_id:
            # claude rejected the resume (unknown id, deleted transcript): start fresh next time
            log.warning("resume of the last session failed; the next message starts a new one")
            self.session_id = None
            self._saved_id = None
            self._delete_last_session()
        self._emit({"type": "error", "kind": kind, "message": message})
        if mid_turn:
            self._record_completion('interrupted' if self._interrupted else 'error')
            self._interrupted = False
        self._set_state("error")

    async def _close(self, p: _Proc | None) -> None:
        """stdin EOF, then SIGTERM after CLOSE_GRACE, then SIGKILL."""
        if p is None:
            return
        p.expected_exit = True
        if self._watchdog is not None:
            self._watchdog.cancel()
        try:
            p.proc.stdin.close()
        except (OSError, RuntimeError):
            pass
        for action in (None, "terminate", "kill"):
            if action is not None:
                try:
                    getattr(p.proc, action)()
                except ProcessLookupError:
                    pass
            done, _ = await asyncio.wait({p.task}, timeout=self.CLOSE_GRACE)
            if done:
                return
        log.warning("claude process %s did not finish after SIGKILL", p.proc.pid)

    async def _interrupt_watchdog(self, p: _Proc, turn_done: asyncio.Event) -> None:
        async def turn_or_exit(timeout: float) -> bool:
            waiter = asyncio.ensure_future(turn_done.wait())
            try:
                done, _ = await asyncio.wait({waiter, p.task}, timeout=timeout,
                                             return_when=asyncio.FIRST_COMPLETED)
            finally:
                waiter.cancel()
            return bool(done)

        try:
            if await turn_or_exit(self.INTERRUPT_GRACE) or p.dead:
                return
            log.warning("no result %.1fs after interrupt; sending SIGINT", self.INTERRUPT_GRACE)
            p.forced = True
            p.proc.send_signal(signal.SIGINT)
            if await turn_or_exit(self.INTERRUPT_GRACE):
                if not p.dead:
                    p.forced = False  # it answered after all and is still alive
                return
            p.proc.terminate()
        except ProcessLookupError:
            pass

    # ------------------------------------------------------------------ stdout handling

    def _handle_line(self, p: _Proc, line: bytes) -> None:
        text = line.decode("utf-8", "replace").strip()
        if not text:
            return
        try:
            raw = json.loads(text)
        except ValueError:
            log.debug("non-JSON line from claude ignored")
            return
        if not isinstance(raw, dict):
            return
        if raw.get('type') == 'control_response':
            reply = raw.get('response') or {}
            if reply.get('request_id') == p.initialize_id and reply.get('subtype') == 'success':
                self._set_commands((reply.get('response') or {}).get('commands'))
                p.initialized.set()
                self._emit({'type': 'commands', 'commands': self._command_list()})
            return
        if raw.get('type') == 'result' and not self._turn_has_output:
            output = raw.get('result')
            if isinstance(output, str) and output:
                self._emit({'type': 'assistant_text_done', 'block_id': 'command-' + uuid.uuid4().hex,
                            'text': cp._clean_text(output)})
        if raw.get("type") == "control_request":
            self._handle_control_request(p, raw)
            return
        for ev in self._norm.feed(raw):
            if ev.get("type") == "session_started":
                p.started = True
            self._handle_event(ev)

    def _handle_control_request(self, p: _Proc, raw: dict) -> None:
        rid = raw.get("request_id")
        req = raw.get("request")
        if not isinstance(req, dict) or req.get("subtype") != "can_use_tool":
            if rid is not None:
                self._write_nowait(p, cp.control_error(rid, "unsupported"))
            return
        if not isinstance(rid, str) or not rid:
            log.warning("can_use_tool without request_id ignored")
            return
        self.pending[rid] = {
            "tool_name": req.get("tool_name") or "",
            # full original input, sent back as updatedInput (never null)
            "input": req.get("input") if req.get("input") is not None else {},
            "permission_suggestions": req.get("permission_suggestions"),
        }
        for ev in self._norm.feed(raw):
            self._emit(ev)
        self._set_state("waiting_permission")
        self._changed()

    def _handle_event(self, ev: dict) -> None:
        t = ev.get("type")
        if t in ('assistant_text_done', 'assistant_text_delta'):
            self._turn_has_output = True
        if t == "session_started":
            self._set_commands(ev.get('slash_commands'), merge=True)
            ev['slash_commands'] = self._command_list()
            sid = ev.get("session_id")
            if isinstance(sid, str) and sid and not sid.startswith("-"):
                self.session_id = sid
                self._fork_from = None
                self._fork_at = None
                if sid != self._saved_id:
                    self._save_last_session(sid)
        if t == "turn_result":
            stopped = self._interrupted or ev.get('subtype') == 'interrupted'
            if self._interrupted and not ev.get("ok"):
                # claude reports a user interrupt as error_during_execution with an internal
                # diagnostic text; show it as a stop, not as a failure
                ev = {k: v for k, v in ev.items() if k != "error"}
                ev["subtype"] = "interrupted"
            self._interrupted = False
            self._record_completion('interrupted' if stopped else 'success' if ev.get('ok') else 'error')
        self._emit(ev)
        if t == "turn_result":
            self._turn_done.set()
            if not ev.get("ok") and cp.is_auth_error(ev.get("error")):
                self._emit({"type": "error", "kind": "auth", "message": ev.get("error")})
                self._set_state("error")
            else:
                self._set_state("waiting_permission" if self.pending else "idle")

    # ------------------------------------------------------------------ events

    def _record_completion(self, kind):
        self._completion_id += 1
        self.completion = {'id': self._completion_id, 'kind': kind}
        self._changed()

    def _emit(self, ev: dict) -> None:
        if ev.get("type") == "assistant_text_delta":
            self._deltas.setdefault(ev.get("block_id"), []).append(ev.get("text") or "")
            if self._flush_handle is None:
                loop = asyncio.get_running_loop()
                self._flush_handle = loop.call_later(self.COALESCE_SECONDS, self._flush_deltas)
            return
        self._flush_deltas()
        self._append(ev)

    def _flush_deltas(self) -> None:
        if self._flush_handle is not None:
            self._flush_handle.cancel()
            self._flush_handle = None
        deltas, self._deltas = self._deltas, {}
        for block_id, parts in deltas.items():
            self._append({"type": "assistant_text_delta", "block_id": block_id, "text": "".join(parts)})

    def _append(self, ev: dict) -> None:
        ev["session_id"] = self.session_id
        self.log.append(ev)

    def _set_state(self, state: str) -> None:
        assert state in STATES, state
        if state != self.state:
            self.state = state
            self._changed()

    def _changed(self) -> None:
        try:
            self._on_change()
        except Exception:  # noqa: BLE001
            log.exception("on_change callback failed")

    # ------------------------------------------------------------------ permissions helpers

    async def _deny_all(self, p: _Proc | None, message: str, interrupt: bool = False) -> None:
        if not self.pending:
            return
        for rid in list(self.pending):
            del self.pending[rid]
            sent = await self._write(p, cp.permission_deny(rid, message, interrupt=interrupt))
            self._emit({"type": "permission_resolved", "request_id": rid,
                        "decision": "deny" if sent else "cancelled"})
        self._after_pending_change()

    def _cancel_pending(self, decision: str) -> None:
        """The process is gone: its requests can no longer be answered."""
        if not self.pending:
            return
        for rid in list(self.pending):
            del self.pending[rid]
            self._emit({"type": "permission_resolved", "request_id": rid, "decision": decision})
        self._changed()

    def _after_pending_change(self) -> None:
        if not self.pending and self.state == "waiting_permission":
            self._set_state("running")
        self._changed()

    # ------------------------------------------------------------------ stdin

    def _next_req_id(self) -> str:
        self._req_counter += 1
        return f"bridge-{self._req_counter}-{uuid.uuid4().hex[:8]}"

    @staticmethod
    def _encode(obj: dict) -> bytes:
        # ensure_ascii=True: lone surrogates from the UI cannot break UTF-8 encoding
        return (json.dumps(obj) + "\n").encode("ascii")

    def _write_nowait(self, p: _Proc | None, obj: dict) -> bool:
        if p is None or p.dead or p.proc.stdin is None or p.proc.stdin.is_closing():
            return False
        try:
            p.proc.stdin.write(self._encode(obj))
        except (BrokenPipeError, ConnectionResetError, RuntimeError):
            return False
        return True

    async def _write(self, p: _Proc | None, obj: dict) -> bool:
        if not self._write_nowait(p, obj):
            return False
        try:
            await p.proc.stdin.drain()
        except (BrokenPipeError, ConnectionResetError):
            return False  # the exit handler reports the crash
        return True

    # ------------------------------------------------------------------ last_session.json

    def _last_session_path(self) -> Path:
        return self._data_dir / LAST_SESSION_FILE

    def _load_last_session(self) -> str | None:
        try:
            data = json.loads(self._last_session_path().read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        sid = data.get("session_id") if isinstance(data, dict) else None
        if isinstance(sid, str) and sid and not sid.startswith("-"):
            return sid
        return None

    def _save_last_session(self, sid: str) -> None:
        path = self._last_session_path()
        tmp = path.with_name(path.name + ".tmp")
        try:
            self._data_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w", encoding="ascii") as f:
                os.fchmod(f.fileno(), 0o600)
                f.write(json.dumps({"session_id": sid}))
            os.replace(tmp, path)
            self._saved_id = sid
        except OSError:
            log.exception("cannot write %s", path)

    def _delete_last_session(self) -> None:
        try:
            self._last_session_path().unlink()
        except FileNotFoundError:
            pass
        except OSError:
            log.exception("cannot delete last_session.json")
