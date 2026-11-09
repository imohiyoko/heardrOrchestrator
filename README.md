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
| [`taskboard/`](taskboard/README.md) | `tb` CLI: SQLite task table, worker reports, hook-based activity tracking (bash, sqlite3, jq) |
| [`webui/`](webui/README.md) | Read-only progress web UI with login (Python standard library only) |
| [`scheduler/`](scheduler/README.md) | Periodic prompts / commands via launchd, driven by `jobs/*.conf` |
| [`presets/`](presets/example.conf) | Example workspace presets for `herdr-up.sh` |
| [`herdr-up.sh`](herdr-up.sh) | Creates workspaces and starts agents from a preset |
| [`conductor/`](conductor/README.md) | Description of the conductor role |

## Usage

Each component has its own README and test script:

```
bash taskboard/test/run.sh
bash webui/tests/run.sh
bash scheduler/tests/run.sh
```

Tests use fake `herdr` binaries and do not touch a real herdr, launchd, or the network. Runtime state (`data/`, `run/`, `logs/`, `generated/`) is git-ignored.

Copy `scheduler/jobs/*.conf.example` to `*.conf` and adjust before use.
