#!/usr/bin/env python3
"""Bridge entrypoint (spec §5.3–5.4). Run as `python3 -I bridge/agentd.py --data-dir DIR ...`.

stdout belongs to Noctalia's `runStream`: the first line is
`{"type":"ready","port":N,"token":"…","version":"0.1.0","pid":P}`, then `{"type":"ping"}`
every 5 s. A failed write (EPIPE: Noctalia is gone) shuts the bridge down. Logs go to stderr.
The token exists only in memory and on that pipe: never in argv, env or files.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import argparse  # noqa: E402
import asyncio  # noqa: E402
import errno  # noqa: E402
import fcntl  # noqa: E402
import json  # noqa: E402
import logging  # noqa: E402
import secrets  # noqa: E402
import signal  # noqa: E402
import time  # noqa: E402

from bridge import claude_proto as cp  # noqa: E402
from bridge import http_api  # noqa: E402
from bridge.session import Session  # noqa: E402

log = logging.getLogger("agentd")

MARKER = "CLAUDE_AGENT_BRIDGE"
PING_SECONDS = 5.0
LOCK_WAIT_SECONDS = 3.0
SHUTDOWN_TIMEOUT = 20.0
LOG_LEVELS = {"warn": logging.WARNING, "info": logging.INFO, "debug": logging.DEBUG}


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(prog="agentd.py", description="System AI Agent bridge for Noctalia")
    p.add_argument("--data-dir", required=True)
    p.add_argument("--runtime-dir")
    p.add_argument("--claude-path")
    p.add_argument("--cwd", default="~")
    p.add_argument("--model", default="default")
    p.add_argument("--permission-mode", default="bypassPermissions", choices=cp.ALLOWED_MODES)
    p.add_argument("--effort", default="default", choices=cp.ALLOWED_EFFORTS)
    p.add_argument("--safe-mode", action="store_true")
    p.add_argument("--log-level", default="warn", choices=tuple(LOG_LEVELS))
    return p.parse_args(argv)


def ensure_marker() -> None:
    """Re-exec (same pid, same pipes) with CLAUDE_AGENT_BRIDGE=1 in the environment, so a
    later instance can recognise this process in /proc/<pid>/environ before signalling it."""
    if os.environ.get(MARKER) == "1":
        return
    env = dict(os.environ, **{MARKER: "1"})
    os.execve(sys.executable, [sys.executable, "-I", str(Path(__file__).resolve()), *sys.argv[1:]], env)


def default_runtime_dir() -> Path:
    base = os.environ.get("XDG_RUNTIME_DIR") or f"/tmp/system-ai-agent-{os.getuid()}"
    return Path(base) / "system-ai-agent"


# --------------------------------------------------------------------------- lock


def _is_bridge(pid: int) -> bool:
    try:
        environ = Path(f"/proc/{pid}/environ").read_bytes().split(b"\0")
        cmdline = Path(f"/proc/{pid}/cmdline").read_bytes()
    except OSError:
        return False
    return f"{MARKER}=1".encode() in environ and b"agentd.py" in cmdline


def _read_pid(fd: int) -> int | None:
    try:
        raw = os.pread(fd, 32, 0).decode("ascii", "replace").strip()
    except OSError:
        return None
    return int(raw) if raw.isdigit() else None


def acquire_lock(path: Path) -> int:
    """flock(path); a live bridge holding it gets SIGTERM and up to 3 s to let go."""
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o600)
    signalled = False
    deadline = time.monotonic() + LOCK_WAIT_SECONDS
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            pass
        if not signalled:
            signalled = True
            pid = _read_pid(fd)
            if pid and pid != os.getpid() and _is_bridge(pid):
                log.warning("replacing the running bridge (pid %d)", pid)
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        if time.monotonic() > deadline:
            os.close(fd)
            raise TimeoutError(f"lock {path} is held by another process")
        time.sleep(0.05)
    os.ftruncate(fd, 0)
    os.pwrite(fd, f"{os.getpid()}\n".encode(), 0)
    return fd


# --------------------------------------------------------------------------- stdout


def write_stdout(obj: dict) -> None:
    """One JSON line straight to fd 1. OSError (EPIPE…) means Noctalia is gone."""
    data = (json.dumps(obj) + "\n").encode("ascii")
    while data:
        n = os.write(1, data)
        data = data[n:]


async def ping_loop(stop: asyncio.Event) -> None:
    while not stop.is_set():
        try:
            await asyncio.wait_for(stop.wait(), PING_SECONDS)
            return
        except TimeoutError:
            pass
        try:
            write_stdout({"type": "ping"})
        except OSError as e:
            log.info("stdout closed (%s); shutting down", errno.errorcode.get(e.errno, e))
            stop.set()


# --------------------------------------------------------------------------- main


async def amain(args: argparse.Namespace, lock_fd: int) -> int:
    cfg = http_api.BridgeConfig(
        claude_path=http_api.resolve_claude_path(args.claude_path), cwd=args.cwd,
        model=args.model, permission_mode=args.permission_mode, effort=args.effort, safe_mode=args.safe_mode)
    if cfg.claude_path is None:
        log.warning("claude executable not found")
    session = Session(http_api.make_opts_factory(cfg), on_change=lambda: None,
                      data_dir=Path(os.path.expanduser(args.data_dir)))
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)

    token = secrets.token_urlsafe(32)
    server, port = await http_api.start_server(session, cfg, token, on_shutdown=stop.set)
    try:
        write_stdout({"type": "ready", "port": port, "token": token,
                      "version": http_api.VERSION, "pid": os.getpid()})
    except OSError:
        stop.set()
    log.info("listening on 127.0.0.1:%d", port)
    pinger = asyncio.create_task(ping_loop(stop))

    await stop.wait()
    log.info("shutting down")
    os.close(lock_fd)  # let a replacement bridge start while we clean up
    server.close()  # no new connections
    try:
        await asyncio.wait_for(session.shutdown(), SHUTDOWN_TIMEOUT)
    except TimeoutError:
        log.warning("session shutdown timed out")
    server.close_clients()
    try:
        await asyncio.wait_for(server.wait_closed(), 2.0)
    except TimeoutError:
        pass
    await pinger
    return 0


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    ensure_marker()
    logging.basicConfig(stream=sys.stderr, level=LOG_LEVELS[args.log_level],
                        format="agentd %(levelname)s %(name)s: %(message)s")
    data_dir = Path(os.path.expanduser(args.data_dir))
    runtime_dir = Path(os.path.expanduser(args.runtime_dir)) if args.runtime_dir else default_runtime_dir()
    try:
        data_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        runtime_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        lock_fd = acquire_lock(runtime_dir / "agentd.lock")
    except (OSError, TimeoutError) as e:
        log.error("cannot start: %s", e)
        return 1
    return asyncio.run(amain(args, lock_fd))


if __name__ == "__main__":
    sys.exit(main())
