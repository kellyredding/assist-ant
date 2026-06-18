---
name: assist-ant-progress
description: Produce a prioritized progress snapshot of the user's day — the clear priorities to work on next and why, with today's meetings woven in — by reading the local item store with `assist-ant briefing`. Use when the user asks what to work on, to reprioritize, for a progress check or status, or when the "Priority capture" task fires. This is also the shared widget-block format the daily startup and end-of-day routines emit.
---

# AssistAnt progress + priorities

Produce one compact, scannable snapshot of what the user should work on **right
now** and why — with today's **meetings** woven in — from their AssistAnt items.
The output is a single monospaced block meant to live in the title-bar Priority
widget (and to read well on its own). You do the judgement the data can't:
deciding what matters most today, how the calendar bends it, and saying it
tightly.

Read everything with `assist-ant briefing` — a read-only snapshot covering
**all** local items, calendar events included. Never query the calendar/Linear
MCP or the network; this skill reasons over the briefing alone, so it stays fast
and deterministic (the sync tasks keep the local mirror fresh). It never writes
items; recording the result to the widget is a separate step (see *Recording*).

## Procedure

1. **Read the snapshot.** Run `assist-ant briefing` (Bash; on PATH). It returns
   one JSON object — a READ, it changes nothing:
   - `today` — the live Today list: overdue + unscheduled + scheduled-for-today
     items, anything **resolved today**, AND **today's calendar events**. Each
     row has `kind` (todo/reminder/explore/**calendar**), `title`, `preview`,
     `scheduledOn`, `resolvedToday`, `source` (manual/linear/gcal), `externalID`
     (e.g. `ABC-123`), `externalURL`, `listName`, `position` (manual rank within
     a list; lower = higher).
   - **Calendar rows** additionally carry `startAt` / `endAt` (ISO-8601 instants)
     and `allDay`. The event's calendar name, RSVP status, location, and
     attendees ride along in `preview` — read them there; do not invent them.
   - `upcoming` — items and events scheduled tomorrow → end of next week.
     **Awareness only** (a deadline or commitment bearing down), not its own
     section.
   - `icebox` — a trend summary (counts only, never the items): `total`,
     `byKind`, `oldestAgeDays`, `olderThan30`.
   - `generatedOn` — "YYYY-MM-DD" (use it for the header date).
   - `lastPriority` — the previously captured snapshot (`{ capturedAt, body }`)
     or null on the first run. Use it in the commentary to note what slipped.
   If `briefing` errors (app not ready), say so in one line and stop.

2. **Drop what's done.** `today` rows with `resolvedToday: true` are already
   complete — use them ONLY to keep finished work out of the ranking. Do **not**
   list them. Likewise, a calendar event whose `endAt` is already past is
   context, not a priority — don't rank it.

3. **Rank the open work, with the calendar bending it.** Order the open `today`
   rows (`resolvedToday: false`, excluding reminders) most-actionable first.
   Weigh:
   - **The calendar anchors the day** — an imminent or soon meeting, and the prep
     it needs, rises to the top; a free block is room for deep work. Fold in
     conflicts (overlapping events) and **pending RSVPs** as actions.
   - **In-flight first** — a started/in-review issue (`source: "linear"`) is the
     highest-priority work to finish.
   - **Deadline pressure** — fold in `upcoming`: due tomorrow or early next week
     outranks an undated item.
   - **Manual intent** — within a list, a lower `position` is the user's own
     higher ranking; respect it, and weave it with a matched Linear issue's
     priority (match on `externalID`).
   - **Quick wins** — a small unblocked item can rank up as an easy clear.
   Treat a `today` row whose `source` is `linear` as the SAME work as its issue
   (match on `externalID`) — never list it twice.

4. **Compose the block — this is the deliverable.** Keep it tight and scannable;
   it renders in a monospaced popover. Rules:
   - **Short lines (aim ≤ 72 chars).** Never write a line that would wrap. Bullets
     and one-line headlines, never paragraphs.
   - **Open with the calendar** — one or two lines: meetings left today with the
     next one's time + title, then a ⚠️ line only if there's a conflict or a
     pending RSVP to act on. Skip the calendar block entirely on a meeting-free
     day.
   - **Then the priorities**, top first — a one-line headline with a leading
     urgency emoji, then at most one short sub-line of *why* it matters (the
     deadline, the meeting it precedes, the blocker, the payoff). Context, not
     item state.
   - **Lean on emoji** as anchors: 🔴 / 🟠 / 🟡 urgency · 📅 meeting · ⏰ deadline ·
     🚀 quick win · ⭐ carried-over · 🚧 blocked · 📌 reminder.
   - **Close with commentary** — a 💬 line or two: the one thing to nail today and
     why, then what slipped (from `lastPriority`) or what can wait. Terse.
   - **Leave out** a "done today" tally and any per-item status dump.

   The example below is illustrative only — invent nothing; build the block from
   the actual `briefing` data. Adapt the shape, drop empty sections, keep lines
   short:

   ```
   🎯 Today · Thu Jun 18

   📅 3 meetings left · next 11:00 Standup, then 14:00 Roadmap review
   ⚠️ 13:30 Design sync needs an RSVP · overlaps your focus block

   🔴 Finish FLEX-3304 review before the 14:00 roadmap call
      ⏰ it's the agenda's first item
   🟠 ABC-212 — unblock the migration (in progress)
      🚧 waiting on the staging backfill
   🚀 Reply to the vendor thread — 2-minute clear
   ⭐ Draft the Q3 outline (carried from Tue)
      • next step: rough the three sections

   📌 Pick up the CR-V from Honda

   💬 Land FLEX-3304 before 14:00; the roadmap call hinges on it.
   💬 Q3 outline can slide to tomorrow — light morning, heavy afternoon.
   ```

5. **Write it to a file** with the Write tool at `/tmp/aa-progress.md` (the raw
   block, nothing else), then print the block inline so it can be reviewed.
   Report the path on the last line, e.g. `Wrote /tmp/aa-progress.md`.

## Recording to the widget

This skill only *produces* the block. To pin it to the title-bar Priority
widget, record the file with the CLI:

```bash
assist-ant priority set --body /tmp/aa-progress.md
```

The "Priority capture" task does this on a schedule, and the daily startup and
end-of-day routines emit this same block alongside their fuller in-session
output. When the user invokes the skill directly for a progress check, just
produce the block — only record it if they ask to pin or refresh it.

## Notes

- The output is just the block. No preamble ("here's your snapshot…"), no
  closing recap beyond the 💬 commentary, and **never** mention where the data
  comes from — not "local", not the item source, not "from your items." The data
  origin is irrelevant to the reader.
- Reasoning over `assist-ant briefing` alone (never the MCP or network) is a
  behavior of this skill, not something to surface in the output.
- Calendar times in the briefing are ISO-8601 instants — render them in the
  user's local time (Central) as plain clock times (e.g. "14:00"), never raw
  ISO. All-day events have no clock time; treat them as day-level context.
- Reminders are day-level: at most one short 📌 line, never with a time, and
  never inside the ranked priorities.
- Be terse. Short lines beat complete sentences; this lives in a popover.
- Run `assist-ant briefing --help` or `assist-ant priority --help` if unsure of a
  flag rather than assuming.
