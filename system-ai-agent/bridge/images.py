"""Images pasted into the chat: read from the Wayland clipboard, stored privately, sent as base64.

Never starts a shell. External tools (wl-paste, magick) get fixed argv and bounded time and output.
"""
from __future__ import annotations

import base64
import os
import re
import shutil
import subprocess
import time
import uuid
from pathlib import Path
from urllib.parse import unquote, urlsplit
from typing import Callable

MAX_IMAGES = 5  # per message
# The Messages API limits an image to 5 MB of base64; 3.75 MB raw stays under it.
MAX_IMAGE_BYTES = 3_750_000
MAX_CLIPBOARD_BYTES = 40_000_000  # refuse to buffer anything larger from the clipboard
KEEP_SECONDS = 7 * 24 * 3600
TOOL_TIMEOUT = 8.0
SHRINK_EDGE = 2000  # long edge after shrinking; the model downsizes past ~1568 px anyway

MAX_PASTE_CHARS = 100_000  # same limit as a message
# Text targets, most specific first (X11 names come from XWayland apps).
TEXT_TYPES = ("text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "STRING", "TEXT")
# Preference order when the clipboard offers several image types.
IMAGE_TYPES = ("image/png", "image/jpeg", "image/webp", "image/gif")
EXT = {"image/png": "png", "image/jpeg": "jpg", "image/webp": "webp", "image/gif": "gif"}
_ID = re.compile(r"^[0-9a-f]{32}$")

# runner(argv, stdin_bytes) -> stdout bytes; raises ImageError on failure. Injectable for tests.
Runner = Callable[[list[str], bytes | None], bytes]


class ImageError(ValueError):
    """Error code: no_image | image_too_large | clipboard_unavailable | invalid_image | image_not_found
    | clipboard_empty | paste_too_long."""


def sniff(data: bytes) -> str | None:
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if data.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if data.startswith((b"GIF87a", b"GIF89a")):
        return "image/gif"
    if len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    return None


def run_tool(argv: list[str], stdin: bytes | None = None) -> bytes:
    if shutil.which(argv[0]) is None:
        raise ImageError("clipboard_unavailable")
    try:
        proc = subprocess.run(argv, input=stdin, capture_output=True, timeout=TOOL_TIMEOUT, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise ImageError("clipboard_unavailable") from None
    if proc.returncode != 0:
        raise ImageError("no_image")
    if len(proc.stdout) > MAX_CLIPBOARD_BYTES:
        raise ImageError("image_too_large")
    return proc.stdout


class ImageStore:
    def __init__(self, directory: Path, runner: Runner | None = None):
        self.dir = Path(directory)
        self._run = runner or run_tool

    # ------------------------------------------------------------------ public

    def paste_clipboard(self) -> dict:
        """The clipboard's image, stored. Raises ImageError(no_image) when it holds none."""
        offered = self._run(["wl-paste", "--list-types"], None).decode("utf-8", "replace").split()
        media_type = next((t for t in IMAGE_TYPES if t in offered), None)
        if media_type is None:
            raise ImageError("no_image")
        data = self._run(["wl-paste", "--no-newline", "--type", media_type], None)
        return self.save(data)

    def paste(self) -> dict:
        """What Ctrl+V should insert: {"kind": "image", ...stored image} or {"kind": "text", "text"}.

        The panel's text field cannot tell: the host pastes the newest *text* from its clipboard
        history even when the clipboard holds a screenshot.
        """
        offered = self._run(["wl-paste", "--list-types"], None).decode("utf-8", "replace").split()
        media_type = next((t for t in IMAGE_TYPES if t in offered), None)
        if media_type is not None:
            return {"kind": "image", **self.save(self._run(["wl-paste", "--no-newline", "--type", media_type], None))}
        if "text/uri-list" in offered:
            image = self._image_file(self._run(["wl-paste", "--no-newline", "--type", "text/uri-list"], None))
            if image is not None:
                return {"kind": "image", **image}
        text_type = next((t for t in TEXT_TYPES if t in offered), None)
        if text_type is None:
            raise ImageError("clipboard_empty")
        text = self._run(["wl-paste", "--no-newline", "--type", text_type], None).decode("utf-8", "replace")
        if len(text) > MAX_PASTE_CHARS:
            raise ImageError("paste_too_long")
        return {"kind": "text", "text": text}

    def _image_file(self, uri_list: bytes) -> dict | None:
        """A single copied image file (file manager "Copy"): stored like a pasted image."""
        uris = [u for u in uri_list.decode("utf-8", "replace").splitlines() if u and not u.startswith("#")]
        if len(uris) != 1:
            return None
        parts = urlsplit(uris[0].strip())
        if parts.scheme != "file" or parts.netloc not in ("", "localhost"):
            return None
        path = unquote(parts.path)
        try:
            if not os.path.isfile(path) or os.path.getsize(path) > MAX_CLIPBOARD_BYTES:
                return None
            with open(path, "rb") as f:
                head = f.read(16)
                if sniff(head) is None:
                    return None
                data = head + f.read()
        except OSError:
            return None
        return self.save(data)

    def save(self, data: bytes) -> dict:
        media_type = sniff(data)
        if media_type is None:
            raise ImageError("invalid_image")
        if len(data) > MAX_IMAGE_BYTES:
            data = self._shrink(data)
            media_type = "image/jpeg"
        self._ensure_dir()
        image_id = uuid.uuid4().hex
        path = self.dir / f"{image_id}.{EXT[media_type]}"
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        name = time.strftime("screenshot-%H%M%S.") + EXT[media_type]
        return {"id": image_id, "path": str(path), "name": name, "media_type": media_type, "size": len(data)}

    def load(self, image_id: str) -> tuple[str, str, str]:
        """(media_type, base64 data, path) of a stored image."""
        if not isinstance(image_id, str) or not _ID.match(image_id):
            raise ImageError("image_not_found")
        for media_type, ext in EXT.items():
            path = self.dir / f"{image_id}.{ext}"
            try:
                data = path.read_bytes()
            except FileNotFoundError:
                continue
            except OSError:
                raise ImageError("image_not_found") from None
            if sniff(data) != media_type:
                raise ImageError("invalid_image")
            return media_type, base64.b64encode(data).decode("ascii"), str(path)
        raise ImageError("image_not_found")

    def prune(self, now: float | None = None) -> int:
        """Delete stored images older than KEEP_SECONDS. Returns how many were removed."""
        cutoff = (now if now is not None else time.time()) - KEEP_SECONDS
        removed = 0
        try:
            entries = list(os.scandir(self.dir))
        except OSError:
            return 0
        for entry in entries:
            stem, _, ext = entry.name.partition(".")
            if not _ID.match(stem) or ext not in EXT.values():
                continue
            try:
                if entry.is_file(follow_symlinks=False) and entry.stat(follow_symlinks=False).st_mtime < cutoff:
                    os.unlink(entry.path)
                    removed += 1
            except OSError:
                continue
        return removed

    # ------------------------------------------------------------------ internals

    def _ensure_dir(self) -> None:
        self.dir.mkdir(parents=True, exist_ok=True)
        os.chmod(self.dir, 0o700)

    def _shrink(self, data: bytes) -> bytes:
        # Without ImageMagick (run_tool raises for a missing binary) a big image stays too large.
        try:
            out = self._run(["magick", "-", "-resize", f"{SHRINK_EDGE}x{SHRINK_EDGE}>",
                             "-quality", "85", "jpeg:-"], data)
        except ImageError:
            raise ImageError("image_too_large") from None
        if sniff(out) != "image/jpeg" or len(out) > MAX_IMAGE_BYTES:
            raise ImageError("image_too_large")
        return out
