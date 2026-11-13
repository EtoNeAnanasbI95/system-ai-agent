"""Bounded local path completion. Never opens file contents or starts a shell."""
from __future__ import annotations

import json
import os
import time
import threading
from collections import OrderedDict
from pathlib import Path

MAX_ATTACHMENTS = 10
MAX_ENTRIES = 10000
MAX_DEPTH = 8
SCAN_SECONDS = 0.25
SKIP = {'.git', 'node_modules', '__pycache__', '.venv', 'venv', 'target', 'dist', '.cache'}


class PathIndex:
    def __init__(self, cwd):
        self.cwd = Path(os.path.expanduser(str(cwd))).absolute()
        self._snapshots = OrderedDict()
        self._lock = threading.RLock()

    def _path(self, raw):
        if not isinstance(raw, str) or not raw or len(raw) > 4096 or '\0' in raw:
            raise ValueError('invalid_path')
        if raw.startswith('~') and raw != '~' and not raw.startswith('~/'):
            raise ValueError('invalid_path')
        path = Path(os.path.expanduser(raw))
        return path if path.is_absolute() else self.cwd / path

    def resolve_file(self, raw):
        try:
            path = self._path(raw).resolve(strict=True)
            if not path.is_file():
                raise FileNotFoundError('path_not_found')
        except (OSError, RuntimeError):
            raise FileNotFoundError('path_not_found') from None
        return {'path':str(path), 'name':path.name}

    def suggest(self, query='', offset=0, limit=4, browse=False):
        if not isinstance(query,str) or len(query)>4096 or '\0' in query:
            raise ValueError('invalid_path')
        key=(query,browse)
        with self._lock:
            if offset == 0 or key not in self._snapshots:
                self._snapshots[key]=self._scan(query,browse)
            self._snapshots.move_to_end(key)
            while len(self._snapshots)>4:
                self._snapshots.popitem(last=False)
            snapshot=self._snapshots[key]
            return {**snapshot,'items':snapshot['items'][offset:offset+limit],'offset':offset,'limit':limit}

    def _scan(self, query, browse):
        if not isinstance(query,str) or len(query)>4096 or '\0' in query:
            raise ValueError('invalid_path')
        explicit = '/' in query or query.startswith('~')
        directory, needle = self.cwd, query.casefold()
        recursive = bool(query) and not explicit and not browse
        if query and (explicit or browse):
            raw = self._path(query)
            if browse and raw.is_dir() or query.endswith('/'):
                directory, needle = raw, ''
            else:
                directory, needle = raw.parent, raw.name.casefold()
        try:
            directory = directory.resolve(strict=True)
            if not directory.is_dir():
                raise FileNotFoundError
        except (OSError,RuntimeError):
            raise FileNotFoundError('path_not_found') from None
        items, visited, truncated = [], 0, False
        deadline = time.monotonic() + SCAN_SECONDS
        stack = [(directory,0)]
        while stack:
            folder, depth = stack.pop()
            try:
                with os.scandir(folder) as entries:
                    for entry in entries:
                        visited += 1
                        if visited > MAX_ENTRIES or time.monotonic()>deadline:
                            truncated=True
                            break
                        if entry.name.startswith('.') and not needle.startswith('.'):
                            continue
                        try:
                            is_link=entry.is_symlink()
                            is_dir=entry.is_dir(follow_symlinks=True)
                            if not is_dir and not entry.is_file(follow_symlinks=True):
                                continue
                        except OSError:
                            continue
                        path=Path(entry.path)
                        if recursive and is_dir and not is_link and entry.name not in SKIP and depth<MAX_DEPTH:
                            stack.append((path,depth+1))
                        name=entry.name.casefold()
                        try:
                            relative=str(path.relative_to(self.cwd))
                        except ValueError:
                            relative=str(path)
                        match = not needle or (name.startswith(needle) if explicit or browse else
                                               needle in relative.casefold() or _subsequence(needle,name))
                        if match:
                            items.append({'path':str(path),'name':entry.name,'is_dir':is_dir,'relative':relative})
            except OSError:
                continue
            if truncated:
                break
        items.sort(key=lambda item:(not item['is_dir'], not item['name'].casefold().startswith(needle),
                                    len(item['relative']),item['relative'].casefold()))
        return {'items':items,'total':len(items),
                'cwd':str(self.cwd),'directory':str(directory),'truncated':truncated}


def _subsequence(needle, name):
    chars=iter(name)
    return all(any(c==char for c in chars) for char in needle)


def reference_message(text, attachments, cwd):
    if not isinstance(attachments,list) or len(attachments)>MAX_ATTACHMENTS:
        raise ValueError('invalid_attachments')
    index=PathIndex(cwd)
    paths=list(dict.fromkeys(index.resolve_file(path)['path'] for path in attachments))
    if not paths:
        return text
    return text.rstrip() + '\n\nReferenced local files (paths only; read them if needed):\n' + '\n'.join(
        '- ' + json.dumps(path,ensure_ascii=False) for path in paths)
