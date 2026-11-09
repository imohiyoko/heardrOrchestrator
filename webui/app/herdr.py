"""herdr CLI の呼び出し(読むだけ)と短いキャッシュ。"""

import json
import subprocess
import threading
import time

from .config import CACHE_TTL, HERDR_BIN


_cache = {}
_cache_lock = threading.Lock()


def cached(key, fn):
    now = time.monotonic()
    with _cache_lock:
        hit = _cache.get(key)
        if hit and now - hit[0] < CACHE_TTL:
            return hit[1]
    val = fn()
    with _cache_lock:
        _cache[key] = (time.monotonic(), val)
        if len(_cache) > 200:
            for k in sorted(_cache, key=lambda k: _cache[k][0])[:100]:
                _cache.pop(k, None)
    return val


def run_herdr(args):
    """(出力, エラー文)。herdr が無い・失敗・タイムアウトでも例外にしない。"""
    try:
        p = subprocess.run([HERDR_BIN(), *args], capture_output=True, text=True,
                           timeout=5, stdin=subprocess.DEVNULL, errors="replace")
    except (OSError, subprocess.SubprocessError) as ex:
        return None, f"herdr を実行できません: {type(ex).__name__}"
    if p.returncode != 0:
        return None, f"herdr が失敗しました (exit {p.returncode}): {p.stderr.strip()[:200]}"
    return p.stdout, None


def get_agents():
    def load():
        out, err = run_herdr(["agent", "list"])
        if err:
            return [], err
        try:
            d = json.loads(out)
            agents = d["result"]["agents"]
            if not isinstance(agents, list):
                raise ValueError
            return [a for a in agents if isinstance(a, dict)], None
        except (ValueError, KeyError, TypeError):
            return [], "herdr agent list の出力を解釈できません"
    return cached("agents", load)


def agent_key(a):
    return a.get("name") or a.get("pane_id") or ""


def agent_session(a):
    s = a.get("agent_session")
    return s.get("value") if isinstance(s, dict) else None


def read_agent(a, lines=60, source="recent"):
    """agent read の出力(無害化前)。pane_id は herdr が返した値だけを使う。"""
    pane = a.get("pane_id")
    if not pane:
        return None, "pane_id がありません"

    def load():
        out, err = run_herdr(["agent", "read", pane, "--source", source, "--lines", str(lines), "--format", "text"])
        return out, err
    return cached(("read", pane, lines, source), load)


def workspace_label(ws_id):
    """workspace_id -> 表示ラベル。取れなければ None。"""
    def load():
        out, err = run_herdr(["workspace", "list"])
        if err:
            return {}
        try:
            return {w["workspace_id"]: w.get("label") for w in json.loads(out)["result"]["workspaces"]}
        except (ValueError, KeyError, TypeError):
            return {}
    return cached("workspaces", load).get(ws_id)
