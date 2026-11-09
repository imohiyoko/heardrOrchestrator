"""scheduler のジョブ定義と、Web UI から書く上書き設定(scheduler/settings/)。"""

import json
import os
import re
import subprocess
import time

from .config import JOB_RE, SCHED_JOBS, SCHED_LOGS, SCHED_ROOT, SCHED_SETTINGS
from .sanitize import clean
from .data import parse_jsonl, tail_lines


HM_RE = re.compile(r"([01][0-9]|2[0-3]):[0-5][0-9]")
DAY_TOKENS = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")
DAY_PRESETS = (("daily", "毎日"), ("weekdays", "平日"), ("weekends", "土日"))


def job_names():
    try:
        return sorted(n[:-5] for n in os.listdir(SCHED_JOBS()) if n.endswith(".conf") and JOB_RE.fullmatch(n[:-5]))
    except OSError:
        return []


def job_info(name):
    """scheduler/bin/show.sh で、実際に効く設定(conf + settings)を得る。(dict, None) か (None, エラー文)。"""
    env = dict(os.environ, JOBS_DIR=SCHED_JOBS(), SCHED_SETTINGS_DIR=SCHED_SETTINGS())
    for k in ("SCHED_WINDOW", "SCHED_START", "SCHED_END", "SCHED_INTERVAL_MIN"):
        env.pop(k, None)
    try:
        r = subprocess.run(["bash", os.path.join(SCHED_ROOT, "bin", "show.sh"), name], env=env,
                           capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return None, "設定を読めませんでした"
    if r.returncode != 0:
        return None, clean(r.stderr.strip().splitlines()[-1] if r.stderr.strip() else "設定を読めませんでした")
    try:
        return json.loads(r.stdout), None
    except ValueError:
        return None, "設定を読めませんでした"


def job_last(name):
    recs = parse_jsonl(tail_lines(os.path.join(SCHED_LOGS(), name + ".log"), 200))
    last = recs[-1] if recs else None
    ran = [r for r in recs if r.get("action") in ("ran", "failed", "sent")]
    return last, (ran[-1] if ran else None)


def save_job_settings(name, form):
    """フォームを検証して settings を書く。エラー文か None。"""
    path = os.path.join(SCHED_SETTINGS(), name + ".settings")
    if os.path.islink(path):
        return "settings がシンボリックリンクです。手で確認してください"
    old = None
    if os.path.exists(path):
        with open(path) as f:
            old = f.read()
    if form.get("action") == "reset":
        if old is not None:
            os.unlink(path)
        return None
    iv, start, end = form.get("interval_min", "").strip(), form.get("start", "").strip(), form.get("end", "").strip()
    if not iv.isdigit() or not 1 <= int(iv) <= 1440:
        return "間隔は 1〜1440 分の整数で入力してください"
    if not HM_RE.fullmatch(start) or not HM_RE.fullmatch(end):
        return "開始・終了は HH:MM で入力してください"
    if start > end:
        return "開始は終了より前にしてください(日またぎは未対応)"
    days = form.get("days", "")
    if days == "custom":
        picked = [t for t in DAY_TOKENS if form.get("day_" + t) == "1"]
        if not picked:
            return "曜日を 1 つ以上選んでください"
        days = " ".join(t.capitalize() for t in picked)
    elif days not in dict(DAY_PRESETS):
        return "曜日の指定が不正です"
    enabled = "1" if form.get("enabled") == "1" else "0"
    body = f"# Web UI が書く上書き設定({time.strftime('%Y-%m-%dT%H:%M:%S%z')})\n" \
           f"INTERVAL_MIN={int(iv)}\nSTART={start}\nEND={end}\nDAYS={days}\nENABLED={enabled}\n"
    os.makedirs(SCHED_SETTINGS(), exist_ok=True)
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(body)
    os.replace(tmp, path)
    _, err = job_info(name)
    if err:  # scheduler 側で読めない設定は残さない
        if old is None:
            os.unlink(path)
        else:
            with open(path, "w") as f:
                f.write(old)
        return "scheduler が設定を受け付けませんでした: " + err
    return None
