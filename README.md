# heardrOrchestrator

Building blocks for running several Claude agents on herdr: one **conductor** agent, a **task board**, a read-only **web UI**, and a **scheduler** for periodic prompts.

```
conductor  <--- reports ---  workers (herdr panes)
    |                              |
    +---- task board (sqlite) -----+
              |             |
           web UI       scheduler (launchd)
```

## Layout

| Path | What it is |
|---|---|
| [`taskboard/`](taskboard/README.md) | `tb` CLI: SQLite task table, worker reports batched to the conductor every 10 min (`tb digest`), conductor → worker sends with sender check and routing rules (`tb send`), a log of every message tb sends, hook-based activity tracking, agent lifecycle (`tb agent-new` / `agent-stop` / `agent-revive`, with a "safe to stop" flag set by a light-model sweeper agent) (bash, sqlite3, jq) |
| [`webui/`](webui/README.md) | Read-only progress web UI with login (Python standard library only) |
| [`scheduler/`](scheduler/README.md) | Periodic prompts / commands via launchd, driven by `jobs/*.conf` |
| [`presets/`](presets/example.conf) | Example workspace presets for `herdr-up.sh` |
| [`herdr-up.sh`](herdr-up.sh) | Creates workspaces and starts agents from a preset |
| [`conductor/`](conductor/README.md) | Description of the conductor role |
| [`roles/`](roles/README.md) | Role files handed to each agent on startup / after compact (SessionStart hook), maintained by the HR agent |
| [`lib/`](lib/herdr-env.sh) | Defaults shared by every component (repo root, DB path, herdr binary, schema dir), in bash and Python |
| [`setup/`](setup/README.md) | Setup agent (`./herdr-up.sh setup`) that walks you through the setup and asks before writing any settings, plus a read-only doctor `setup/check.sh` |

## Usage

Each component has its own README and test script:

```
bash tests/run-all.sh          # 全部(GitHub Actions でも同じものを流す)。webui の SQL を本物のスキーマで確かめる tests/test_webui_queries.py も含む
bash taskboard/test/run.sh
bash webui/tests/run.sh
bash scheduler/tests/run.sh
bash setup/tests/run.sh
```

Tests use fake `herdr` binaries and do not touch a real herdr, launchd, or the network. Runtime state (`data/`, `run/`, `logs/`, `generated/`) is git-ignored.

Copy `scheduler/jobs/*.conf.example` to `*.conf` and adjust before use, or start the setup agent with `./herdr-up.sh setup` and let it guide you. `bash setup/check.sh` shows what is installed and what is missing.

## License

Copyright 2026 imohiyoko

Licensed under the [Apache License, Version 2.0](LICENSE).
