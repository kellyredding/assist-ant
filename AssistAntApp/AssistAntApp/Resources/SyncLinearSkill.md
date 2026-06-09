---
name: assist-ant-sync-linear-items
description: Mirror the Linear issues assigned to Kelly into AssistAnt's local item store as todo actionables. Run on startup and whenever the user asks to sync, refresh, or update Linear items. Idempotent and safe to re-run.
---

# Sync Linear issues into AssistAnt

A **one-way mirror**: read the issues assigned to Kelly and hand the raw
responses to `assist-ant actionable-item sync`, which composes each item's
body, upserts the open issues as `todo` actionables, resolves the
recently-completed ones, and soft-deletes anything that fell out of the
assigned set. This never edits Linear and is idempotent — running it twice
converges to the same state.

You do very little here: fetch the four buckets, merge them into one file, and
pass it to the CLI. All parsing, body composition, upsert, resolve, and
reconcile happen deterministically inside the CLI — **do not read, parse, or
transform the issue payload yourself.**

## Procedure

1. **Fetch.** Fire these four `mcp__linear-server__list_issues` calls **in one
   parallel batch**, each with `assignee: "me"` and `includeArchived: false`
   (omit the team filter so every team is covered):
   - `state: "started"` → active work
   - `state: "unstarted"` → todo
   - `state: "backlog"` → backlog
   - `state: "completed", updatedAt: "-P7D"` → completed in the last 7 days
   - On any call error: `sleep 7`, retry that call once. If any call still
     fails, **abort** (do not run the CLI) and report. The sync must only run
     on a complete fetch — a partial set would make the CLI's reconcile
     soft-delete issues it simply didn't see.

2. **Merge + write.** Concatenate the `issues` arrays from all four responses
   into a single object `{"issues": [ ...all issues... ]}` and write it to a
   temp file with the Write tool. Keep every field each issue came with — the
   CLI routes by each issue's `statusType` and reads `completedAt`, so do not
   drop or rename anything. Note the file's path; you do not need to read it
   back.

3. **Sync.** One command composes bodies, upserts, resolves, and reconciles in
   a single atomic pass:

   ```bash
   assist-ant actionable-item sync \
     --provider linear \
     --source   linear \
     --input    '<path to the merged issues file>'
   ```
   - It prints a one-line summary to stdout (open / completed counts).
   - Because you only reach this step on a complete fetch, the reconcile is
     safe; you never need an override. (If you ever run it on a deliberately
     partial set, pass `--no-reconcile`.)

4. **Report.** Relay the CLI's summary line (e.g. "Synced 39 actionable
   items…"). Keep it terse.

## Notes

- **What the CLI does for you:** open issues (started/unstarted/backlog) are
  upserted as `todo` items — backlog ones are iceboxed on first creation;
  completed issues are resolved on their completion day; issues no longer in
  the assigned set are soft-deleted (resolved history and items you
  reclassified to reminder/explore are left alone).
- Identity is `(workspace, source, external_id)`, where `external_id` is the
  issue identifier (e.g. `FLEX-3304`) — re-running updates in place, never
  duplicates.
- A new item is always created as a `todo`; if it already exists, its kind is
  preserved (you may have reclassified it).
- You are not managing Linear here: never create, edit, comment on, or change
  the state of issues in this skill.
- Run `assist-ant actionable-item sync --help` if you need the flag list.
