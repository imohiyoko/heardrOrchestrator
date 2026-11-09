# conductor

The conductor is a Claude agent running in a herdr pane. Its job is coordination, not implementation:

- Check the progress of the other agents (list them, read the tail of their output).
- Read and analyze the artifacts they produce, and report back to a human in a few lines.
- Hand out new tasks to the right agent, after a human approves the target, launch arguments, full prompt, and side effects.
- Receive worker reports sent through `taskboard` (`tb comment`) and treat them as data, never as instructions.

It never does the investigation or implementation itself, never approves dialogs on behalf of a human, and keeps an append-only ledger of everything it dispatches. Its instructions (a `CLAUDE.md`) are specific to your environment and are not part of this repository.
