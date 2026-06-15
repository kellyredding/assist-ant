---
name: assist-ant-manage-tasks
description: Create, change, list, or remove AssistAnt tasks for the user by driving the `assist-ant task` CLI. A task is a named prompt plus a trigger (recurring on an interval or daily time, a one-shot at a time, or a manual trigger). Use when the user asks to schedule, automate, recur, remind-on-a-cadence, run something on a timer, or stop one of these.
---

# Manage AssistAnt tasks

A task is a **named prompt + a trigger**. When it fires (a later capability),
the prompt is delivered to you in this session and you act on it — so the prompt
is what *you* should later do ("Sync my Linear issues", "Summarize today's
calendar"). You author tasks by running the `assist-ant task` CLI; the app owns
storage and replies with an ack. The Tasks tab only *shows* tasks — there is no
form, so creating and editing always happens here, through you.

Every subcommand needs the app running and returns a one-line result (or a JSON
list). Run `assist-ant task <sub> --help` if unsure of a flag.

## Procedure

1. **Decide the trigger** from how the user phrased the cadence:
   - "every N minutes/hours", "on a timer" → `recurring` + `interval`
     (`--cadence interval --interval-seconds N`).
   - "at 7am", "every morning", "daily at …" → `recurring` + `daily`
     (`--cadence daily --daily-time HH:MM`, resolved to **America/Chicago**).
   - "at 5pm today", a specific date/time, "once" → `one_shot`
     (`--run-at` as full ISO-8601 with offset, e.g. `2026-06-15T17:00:00-05:00`;
     omit to fire on the next tick).
   - "when I hit the calendar refresh" / a built-in hook → `manual`
     (`--manual-key KEY`).

   State anything you couldn't honor: the schema has **no work-hours window or
   weekday filter** — map "every weekday at 9" to the nearest daily/interval and
   say so.

2. **Compose name + prompt.** A short imperative name ("Linear sync", "Morning
   brief"); the prompt is the instruction you'll later carry out. For a
   multi-line prompt, write it to a temp file (e.g. `/tmp/aa-task-<x>.md`) and
   pass `--prompt-file` so newlines survive.

3. **Create** — one call; relay the CLI's one-line ack:

   ```bash
   assist-ant task add \
     --name '<name>' \
     --trigger <recurring|one_shot|manual> \
     [--cadence interval --interval-seconds <N>] \
     [--cadence daily --daily-time HH:MM] \
     [--run-at <ISO8601>] \
     [--manual-key <KEY>] \
     [--disabled] \
     --prompt '<prompt>'      # or --prompt-file '<path>'
   ```

4. **Edit.** Run `assist-ant task list` (JSON `{"tasks":[…]}`), fuzzy/semantic-
   match the target by name, then `assist-ant task update <id> --…` with **only
   the changed fields**. Confirm against the ack.

5. **Remove / enable / disable** — `assist-ant task remove|enable|disable <id>`
   after the same list→match step. For a destructive `remove`, confirm which
   task you matched before running it.

6. **Report** terse — the task's name and what you set, in a sentence.

## Notes

- Tasks authored now are **inert** — there is no runner yet, so a new task sits
  enabled but doesn't fire. Say so if the user expects it to run immediately.
- The CLI validates the trigger/cadence combo and exits non-zero on a bad one
  (e.g. `recurring` with no `--cadence`); the app re-validates and replies
  `{"ok":false,"error":…}` if it still refuses. Surface the error, don't retry
  blindly.
- A missing reply means the app isn't running. It always is while you're in this
  session, so treat "is the app running?" as a real failure to report.
- Run `assist-ant task --help` (or `<sub> --help`) for the current flags rather
  than assuming.
