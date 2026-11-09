#!/usr/bin/env python3
"""webui が tasks.db に投げる SQL が、本物のスキーマ(taskboard/schema/*.sql)でそのまま通るかを確かめる。

webui/app/*.py の文字列リテラルのうち SELECT で始まるものを集め、スキーマを流した空の DB で EXPLAIN する。
列名やテーブル名が tb 側と食い違えば、ここで落ちる(webui は DB のエラーを空の一覧として隠すため)。
"""
import ast
import glob
import os
import sqlite3
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
db = sqlite3.connect(":memory:")
for f in sorted(glob.glob(os.path.join(ROOT, "taskboard", "schema", "[0-9][0-9][0-9]_*.sql"))):
    db.executescript(open(f, encoding="utf-8").read())

found = fail = 0
for path in sorted(glob.glob(os.path.join(ROOT, "webui", "app", "*.py"))):
    for node in ast.walk(ast.parse(open(path, encoding="utf-8").read())):
        if not (isinstance(node, ast.Constant) and isinstance(node.value, str)):
            continue
        sql = node.value.strip()
        if not sql.upper().startswith("SELECT ") or " FROM " not in sql.upper():
            continue
        # 後ろに WHERE などを足して組み立てる文もあるので、文として閉じていなくても FROM 句までで確かめる
        found += 1
        try:
            db.execute("EXPLAIN " + sql, [None] * sql.count("?"))
            print(f"ok   {os.path.basename(path)}:{node.lineno}")
        except sqlite3.Error as ex:
            fail += 1
            print(f"FAIL {os.path.basename(path)}:{node.lineno} {ex}\n     {sql[:160]}")
if found < 10:
    fail += 1
    print(f"FAIL SQL が {found} 件しか見つからない(抽出が壊れている)")
print(f"pass={found - fail} fail={fail}")
sys.exit(1 if fail else 0)
