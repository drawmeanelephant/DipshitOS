"""Minimal TOML parser used only on Python < 3.11 where ``tomllib`` is
unavailable.

It supports exactly what Ragshit configuration files need: ``[section]``
headers, comments, string / integer / float / boolean scalars, and arrays
of scalars. Anything else raises :class:`ValueError` so configuration
errors stay precise even in degraded mode.
"""

from __future__ import annotations

from typing import Any, Dict


def _parse_scalar(raw: str) -> Any:
    v = raw.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        return v[1:-1]
    if v in ("true", "false"):
        return v == "true"
    if v.startswith("["):
        inner = v[1:-1].strip()
        if not inner:
            return []
        items = [part for part in inner.replace(",", " ").split() if part]
        return [_parse_scalar(i) for i in items]
    if v and (v[0] == "-" or v[0].isdigit()):
        body = v.lstrip("-")
        if body.replace(".", "", 1).isdigit():
            return float(v) if "." in body else int(v)
    raise ValueError(f"cannot parse TOML value: {raw!r}")


def loads(text: str) -> Dict[str, Dict[str, Any]]:
    """Parse a TOML document into ``{section: {key: value}}``."""
    data: Dict[str, Dict[str, Any]] = {}
    section: Dict[str, Any] = {}
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            name = line[1:-1].strip()
            section = data.setdefault(name, {})
            continue
        if "=" not in line:
            raise ValueError(f"line {lineno}: expected 'key = value' or '[section]'")
        key, _, value = line.partition("=")
        key = key.strip()
        if not key:
            raise ValueError(f"line {lineno}: empty key")
        section[key] = _parse_scalar(value)
    return data
