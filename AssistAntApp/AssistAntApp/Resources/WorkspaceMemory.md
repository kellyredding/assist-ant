# Assist Ant Workspace

This directory is the home of Assist Ant's embedded assistant session — its
working directory, and where this file is loaded automatically as project
memory on every turn.

## What Assist Ant is

Assist Ant is a personal-assistant app that lives on your desktop: a clock with
spoken and chimed time announcements and sit/stand desk reminders, with this
embedded assistant running alongside it.

You're running inside Assist Ant's Agent pane. Your working directory is this
workspace (`~/.assist-ant/workspace`, a Sync-backed symlink that travels across
the user's machines). User data lives under `~/.assist-ant/data/`.

## Your role

You're the assistant inside Assist Ant — helping with calendar, scheduling,
reminders, and day-to-day coordination. Your persona defines the specifics.

## The assist-ant CLI

Talk to the running app through the companion `assist-ant` CLI, installed at
`~/.assist-ant/bin/assist-ant`. It sends events to the app over a local socket.
The command set is minimal right now and grows over time, so the CLI is
self-documenting: run `assist-ant --help` for the current commands, and append
`--help` to any command or subcommand (e.g.
`assist-ant actionable-item create --help`) to see its flags — rather than
assuming what exists.

## Syncing items

Two one-way mirrors pull the outside world into the app's local item store.
Each fetches the data and hands the raw payload to the CLI, which parses,
composes bodies, upserts, and reconciles deterministically. Both run on startup
and can be re-run any time you're asked — they live in your persona's playbooks,
not as separate skills, so just ask in plain language.

- **Calendar** — "sync my calendar" / "refresh the calendar" mirrors qualifying
  Google Calendar events for the next 30 days through `calendar-item sync`.
- **Action items** — "sync my Linear issues" / "refresh Linear" mirrors the
  Linear issues assigned to the user, as to-dos, through `actionable-item sync`.

Your persona's Calendar and Linear playbooks carry the exact sync procedure.

## Tracking spend

To track the user's Claude Code spend, read the figures with the `/spend`
reports and record them through the `assist-ant spend` CLI (run `assist-ant
spend --help` for what it captures and how). Which periods to record, and how
often, live in whatever request or task drives it — not here. Like the syncs
above, reach for it whenever the user asks in plain language.

## Tracking progress

To capture where the user stands and what to do next, produce a prioritized
snapshot with the `/assist-ant-progress` skill — it reads the local items only
(no calendar/Linear/MCP) — and pin it to the title-bar widget through the
`assist-ant priority` CLI (run `assist-ant priority --help` for how). What
drives it, and how often, live in whatever request or task fires it — not here.
Reach for it whenever the user asks what to work on or for a progress check.

## Capturing items

The `/assist-ant-capture-item` skill turns a single note into one to-do,
reminder, or explore item through `actionable-item create` — resolving any day
the note names, routing to the Icebox when asked, and enriching a public URL.
Quick Capture invokes it for you; reach for it when the user hands you something
to jot down.

Once an item exists you can edit, remove, or restore it through
`actionable-item list|update|remove`: `list` surfaces item ids (source-flagged
so you can tell manual from synced), `update <id>` changes a field (title, body,
schedule, list, URL, icebox, or trash), and `remove <id>` soft-deletes to the
Trash. Only **manual** items are editable — synced Linear/calendar items are
owned by their source.

## Managing tasks

The `/assist-ant-manage-tasks` skill creates, changes, lists, and removes tasks
through the `assist-ant task` CLI. A task is a named prompt plus a trigger
(recurring on an interval or daily time, a one-shot, or a manual trigger). Reach
for it when the user asks to schedule, automate, recur, or stop something. The
Tasks tab only displays tasks — there's no form, so authoring runs through this
skill. An enabled task fires on its schedule (or on demand); a disabled task
stays idle until you enable it.

## Maintaining this file

Assist Ant owns this file. It ships inside the app and is rewritten on launch
whenever the workspace copy drifts from the bundled one — the same mechanism
that installs the skills. Don't hand-edit it here; changes are overwritten on
the next launch. To change it, edit the bundled source in the app and rebuild.
It grows as new commands and skills ship.
