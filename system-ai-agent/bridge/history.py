"""Read-only, cached projection of main Claude Code transcripts. No SDK dependency."""
from __future__ import annotations

import datetime as dt
import json
import os
import re
import stat
import threading
import uuid
from pathlib import Path

from . import claude_proto as cp

MAX_LINE = 16 * 1024 * 1024
_REMINDERS = re.compile(r'<system-reminder>.*?</system-reminder>', re.S)


def _visible_text(record):
    if record.get('isMeta') or record.get('isCompactSummary'):
        return ''
    message = record.get('message')
    if not isinstance(message, dict):
        return ''
    content = message.get('content', '')
    if isinstance(content, list):
        content = '\n'.join(c.get('text', '') for c in content
                            if isinstance(c, dict) and c.get('type') == 'text' and isinstance(c.get('text'), str))
    if not isinstance(content, str):
        return ''
    text = _REMINDERS.sub('', content).strip()
    if text.startswith(('<task-notification>', '<local-command-caveat>', '<local-command-stdout>',
                        '<command-name>', '[Request interrupted by user]', 'Base directory for this skill:')):
        return ''
    return cp._clean_text(text)


def _uuid(s):
    try:
        if not isinstance(s, str) or str(uuid.UUID(s)) != s:
            raise ValueError('invalid_session')
    except (ValueError, AttributeError):
        raise ValueError('invalid_session') from None
    return s


class SessionCatalog:
    def __init__(self, root=None):
        self.root = Path(root) if root is not None else Path(
            os.path.expanduser(os.environ.get('CLAUDE_CONFIG_DIR', '~/.claude'))) / 'projects'
        self._cache = {}
        self._lock = threading.RLock()

    def _paths(self):
        try:
            for project in self.root.iterdir():
                if project.is_symlink() or not project.is_dir():
                    continue
                for path in project.glob('*.jsonl'):
                    if path.is_symlink():
                        continue
                    try:
                        _uuid(path.stem)
                    except ValueError:
                        continue
                    yield path
        except OSError:
            return

    def _read(self, path, with_messages=False):
        # O_NOFOLLOW guards replacement between catalog discovery and opening.
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as f:
            st = os.fstat(f.fileno())
            if not stat.S_ISREG(st.st_mode) or path.parent.is_symlink():
                raise FileNotFoundError(path)
            key = (st.st_dev, st.st_ino, st.st_mtime_ns, st.st_size)
            cached = self._cache.get(path)
            if cached and cached[0] == key and not with_messages:
                return (cached[1], []) if cached[1] else None
            records = []
            while line := f.readline(MAX_LINE + 1):
                if len(line) > MAX_LINE:
                    while not line.endswith(b'\n'):
                        line = f.readline(MAX_LINE + 1)
                        if not line:
                            break
                    continue
                try:
                    r = json.loads(line)
                except (ValueError, UnicodeError):
                    continue
                if isinstance(r, dict) and not r.get('isSidechain'):
                    if r.get('type') in ('user', 'assistant', 'ai-title', 'custom-title', 'summary') or (
                            r.get('type') == 'system' and r.get('subtype') in ('local_command_output', 'compact_boundary')):
                        compact = {k: r[k] for k in ('type', 'uuid', 'parentUuid', 'message',
                            'cwd', 'timestamp', 'isMeta', 'isCompactSummary', 'customTitle',
                            'aiTitle', 'summary', 'subtype', 'content', 'output') if k in r}
                        if not with_messages and 'message' in compact:
                            compact['message'] = {'content': _visible_text(r)[:160]}
                        records.append(compact)
                    elif isinstance(r.get('uuid'), str):
                        records.append({'uuid': r['uuid'], 'parentUuid': r.get('parentUuid')})
        # A branch is the parent chain ending at the last main message. Include
        # intermediate system/progress UUIDs in the walk, but never render them.
        nodes = {r['uuid']: r for r in records if isinstance(r.get('uuid'), str)}
        leaf = next((r for r in reversed(records) if r.get('type') in ('user', 'assistant', 'system')
                     and isinstance(r.get('uuid'), str)), None)
        if leaf:
            chain, visited = [], set()
            while leaf and leaf['uuid'] not in visited:
                visited.add(leaf['uuid'])
                chain.append(leaf)
                parent = leaf.get('parentUuid')
                leaf = nodes.get(parent) if isinstance(parent, str) else None
            messages = list(reversed(chain))
        else:
            messages = [r for r in records if r.get('type') in ('user', 'assistant')]
        first = next((_visible_text(r) for r in messages if r.get('type') == 'user'
                      and _visible_text(r)), '')
        cwd = next((r['cwd'] for r in reversed(messages) if isinstance(r.get('cwd'), str)), '')
        title = next((r.get('customTitle') for r in reversed(records)
                      if r.get('type') == 'custom-title' and r.get('customTitle')), None)
        title = title or next((r.get('aiTitle') or r.get('summary') for r in reversed(records)
                               if r.get('type') in ('ai-title', 'summary')
                               and (r.get('aiTitle') or r.get('summary'))), None)
        if not first and not any(r.get('type') == 'assistant' for r in messages):
            result = None
        else:
            info = dict(id=path.stem, title=cp._clean_text(str(title or first or path.stem))[:160],
                        cwd=cwd, updated_at=dt.datetime.fromtimestamp(
                            st.st_mtime, dt.timezone.utc).isoformat(), active=False)
            result = (info, messages)
        self._cache[path] = (key, result[0] if result else None)
        return result if with_messages else ((result[0], []) if result else None)

    def _entries(self):
        for path in self._paths():
            try:
                data = self._read(path)
                if data:
                    yield data
            except OSError:
                continue

    def list_sessions(self, query='', offset=0, limit=30):
        with self._lock:
            q = query.casefold()
            entries = [dict(info) for info, _ in self._entries()
                       if not q or q in (info['title'] + '\n' + info['cwd']).casefold()]
            entries.sort(key=lambda x: x['updated_at'], reverse=True)
            return dict(sessions=entries[offset:offset + limit], total=len(entries), offset=offset, limit=limit)

    def _get(self, sid, with_messages=False):
        _uuid(sid)
        for path in self._paths():
            if path.stem == sid:
                try:
                    data = self._read(path, with_messages)
                except OSError:
                    continue
                if data:
                    return data
        raise FileNotFoundError('session_not_found')

    def get_session(self, sid):
        with self._lock:
            return dict(self._get(sid)[0])

    def is_active(self, sid, exclude_pid=None):
        """Best effort live-session detection; stale pid files never count as active."""
        sessions = self.root.parent / 'sessions'
        for path in sessions.glob('*.json'):
            try:
                record = json.loads(path.read_text())
                if not isinstance(record, dict):
                    continue
                pid = int(record.get('pid', 0))
                if record.get('sessionId') != sid or pid <= 0 or pid == exclude_pid:
                    continue
                proc = Path('/proc') / str(pid)
                fields = (proc / 'stat').read_text().rsplit(')', 1)[1].split()
                if str(record.get('procStart')) == fields[19]:
                    return True
            except (OSError, ValueError, TypeError, IndexError):
                continue
        return False

    def events(self, sid, offset=0, limit=100):
        with self._lock:
            info, records = self._get(sid, True)
            normalizer = cp.Normalizer()
            events = []
            for record in records:
                t = record.get('type')
                if t == 'user':
                    text = _visible_text(record)
                    message = record.get('message')
                    content = message.get('content') if isinstance(message, dict) else None
                    images = sum(1 for c in content if isinstance(c, dict) and c.get('type') == 'image') \
                        if isinstance(content, list) and not record.get('isMeta') else 0
                    if text or images:
                        ev = dict(type='user_message', text=text)
                        if images:
                            ev['image_count'] = images
                        events.append(ev)
                    if isinstance(content, str):
                        output = re.fullmatch(r'\s*<local-command-stdout>(.*?)</local-command-stdout>\s*',
                                              content, re.S)
                        if output:
                            events.append(dict(type='assistant_text_done',
                                block_id='local-' + str(record.get('uuid')), text=cp._clean_text(output[1])))
                if t in ('user', 'assistant', 'system'):
                    # Normalizer emits tool results for user records, never approvals.
                    events.extend(normalizer.feed(record))
            for e in events:
                e.update(historical=True, session_id=info['id'])
            if offset < 0:
                offset = max(0, len(events) - limit)
            return dict(events=events[offset:offset + limit], total=len(events), offset=offset, limit=limit)
