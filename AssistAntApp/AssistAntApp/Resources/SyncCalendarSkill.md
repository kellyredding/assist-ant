---
name: assist-ant-sync-calendar-items
description: Mirror qualifying Google Calendar events into AssistAnt's local item store for the next 30 days. Run on startup and whenever the user asks to sync, refresh, or update calendar items. Idempotent and safe to re-run.
---

# Sync calendar items into AssistAnt

A **bounded, one-way mirror**: read the calendar and hand the raw response to
`assist-ant calendar-item sync`, which filters to the qualifying events,
composes each item's body, and atomically upserts them while pruning anything
that dropped out of the window. This never edits the calendar and is idempotent
— running it twice converges to the same state.

You do very little here: fetch the window, then pass the response file to the
CLI. All parsing, filtering (timed-only, in-window, RSVP), body composition,
upsert, and prune happen deterministically inside the CLI — **do not read,
parse, or transform the event payload yourself.**

## Procedure

1. **Now + window.** Call `mcp__google-calendar__get-current-time`. Compute:
   - `timeMin` = today 00:00:00 in America/Chicago
   - `timeMax` = today + 30 days, 23:59:59 in America/Chicago
   - `FROM` = today's date `YYYY-MM-DD`; `TO` = (today + 30 days) `YYYY-MM-DD`

2. **Fetch.** One `mcp__google-calendar__list-events` call with `calendarId` set
   to the JSON-stringified array of all six roster calendars, `timeZone:
   "America/Chicago"`, and the window. On error: `sleep 7`, retry once. If it
   still fails, **abort** (do not run the sync) and report.
   - Roster: `kelly.redding@kajabi.com`, `kdredding@gmail.com`,
     `se33hek3vjmu5k3dhdqbvcq348@group.calendar.google.com`,
     `76g7qc6v4csb7c31lagle78cs2e5or7l@import.calendar.google.com`,
     `85mkf4bsi8jo2bd4vggnnk0mu0@group.calendar.google.com`,
     `en.usa#holiday@group.v.calendar.google.com`
   - The response is large and is saved to a file. **Note that file's path —
     do not read its contents into your context;** you only need the path. (If
     it came back inline because it was small, write it to a temp file with the
     Write tool and use that path.)

3. **Sync.** One command filters, composes bodies, upserts, and prunes the
   window in a single atomic pass:

   ```bash
   assist-ant calendar-item sync \
     --provider google-calendar \
     --source   gcal \
     --from     '<FROM>' \
     --to       '<TO>' \
     --input    '<path to the list-events response file>'
   ```
   - It prints a one-line summary to stdout.
   - It skips the prune automatically when nothing qualified, so a degraded or
     empty fetch can never wipe the window — you never need an override.

4. **Report.** Relay the CLI's summary line (e.g. "Synced 47 calendar items…").
   If it reports no qualifying events, say so plainly and flag it as a likely
   degraded fetch. Keep it terse.

## Notes

- The CLI consumes Google's `start.dateTime`/`end.dateTime` **verbatim** and
  derives the local `scheduled_on` itself — there is no timezone math for you
  to do, and you must not pre-convert times.
- Identity is `(workspace, source, external_id)` — re-running updates in place,
  never duplicates; a re-accepted event is resurrected.
- You are not managing the calendar: never create, edit, or RSVP to events here.
- Run `assist-ant calendar-item sync --help` if you need the flag list.
