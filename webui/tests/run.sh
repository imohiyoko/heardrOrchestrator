#!/bin/bash
# 境界のテスト。herdr は疑似。使う実ポートは高位の小範囲だけで、終了時に必ず片付ける。
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."
python3 -m py_compile server.py auth.py app/*.py || exit 1
exec python3 tests/test_webui.py
