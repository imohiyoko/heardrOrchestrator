"""設定: 定数と、環境変数で上書きできるパス。"""

import os
import re
import sys


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # webui/
HERDR_ROOT = os.path.dirname(ROOT)
sys.path.insert(0, os.path.join(HERDR_ROOT, "lib"))
import herdr_env  # noqa: E402  部品で共通の既定値(lib/herdr-env.sh と同じ)

HOST = "127.0.0.1"
COOKIE = "herdr_webui_session"
REFRESH_SEC = 8
CACHE_TTL = 3.0
STALL_MIN = 30  # working のまま最終入力から何分超で滞留警告にするか


def cfg(name, default):
    return os.environ.get(name) or default


HERDR_BIN = herdr_env.herdr_bin
TB_DB = lambda: cfg("WEBUI_TB_DB", herdr_env.tb_db())  # noqa: E731  WEBUI_TB_DB → TB_DB → 既定
SCHED_LOGS = lambda: cfg("WEBUI_SCHED_LOGS", os.path.join(HERDR_ROOT, "scheduler", "logs"))  # noqa: E731
DISPATCH = lambda: cfg("WEBUI_DISPATCH", os.path.join(HERDR_ROOT, "conductor", "dispatch.jsonl"))  # noqa: E731
RUN_DIR = lambda: cfg("WEBUI_RUN_DIR", os.path.join(ROOT, "run"))  # noqa: E731
SCHED_ROOT = os.path.join(HERDR_ROOT, "scheduler")
SCHED_JOBS = lambda: cfg("WEBUI_SCHED_JOBS", os.path.join(SCHED_ROOT, "jobs"))  # noqa: E731
SCHED_SETTINGS = lambda: cfg("WEBUI_SCHED_SETTINGS", os.path.join(SCHED_ROOT, "settings"))  # noqa: E731

JOB_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}")  # ジョブ名(scheduler/jobs/<名前>.conf)
