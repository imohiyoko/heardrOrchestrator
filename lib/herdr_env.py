"""部品で共通の既定値(lib/herdr-env.sh と同じ内容)。片方を変えたらもう片方も変える。"""
import os

HERDR_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_BIN = "herdr"
DEFAULT_TB_DB = os.path.join(HERDR_ROOT, "taskboard", "data", "tasks.db")
SCHEMA_DIR = os.path.join(HERDR_ROOT, "taskboard", "schema")


def herdr_bin():
    return os.environ.get("HERDR_BIN") or DEFAULT_BIN


def tb_db():
    """tb と同じ解決順: TB_DB → 既定。webui はさらに手前で WEBUI_TB_DB を見る。"""
    return os.environ.get("TB_DB") or DEFAULT_TB_DB


def schema_version():
    """taskboard/schema にある最新の版(NNN_*.sql の NNN の最大)。"""
    nums = [int(f[:3]) for f in os.listdir(SCHEMA_DIR) if f[:3].isdigit() and f.endswith(".sql")]
    return max(nums, default=0)
