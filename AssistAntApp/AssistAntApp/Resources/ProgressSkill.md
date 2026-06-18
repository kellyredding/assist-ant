---
name: assist-ant-progress
description: Produce a prioritized progress snapshot of the user's AssistAnt items — the clear priorities to work on next and why — by reading the item store with `assist-ant briefing`. Use when the user asks what to work on, to reprioritize, for a progress check or status, or when the "Priority capture" task fires.
---

# AssistAnt progress + priorities

Produce one compact, scannable snapshot of what the user should work on **right
now** and why, from their AssistAnt items. The output is a single monospaced
block meant to live in the title-bar Priority widget (and to read well on its
own). You do the judgement the data can't: deciding what matters most today and
saying it tightly.

Read the items with `assist-ant briefing` — a read-only snapshot. Never query
the calendar/Linear MCP or the network; this skill reasons over the briefing
data alone, so it stays fast and deterministic. It never writes items; recording
the result to the widget is a separate step (see *Recording*).

## Procedure

1. **Read the snapshot.** Run `assist-ant briefing` (Bash; on PATH). It returns
   one JSON object — a READ, it changes nothing:
   - `today` — the live Today list: overdue + unscheduled + scheduled-for-today
     items, plus anything **resolved today**. Each row has `kind`
     (todo/reminder/explore), `title`, `preview`, `scheduledOn`, `resolvedToday`
     (bool), `source` (manual/linear/gcal), `externalID` (e.g. `ABC-123`),
     `listName`, `position` (manual rank within a list; lower = higher).
   - `upcoming` — items scheduled tomorrow → end of next week. **Awareness only**
     (a deadline bearing down), not its own section.
   - `icebox` — a trend summary (counts only, never the items): `total`,
     `byKind`, `oldestAgeDays`, `olderThan30`.
   - `generatedOn` — "YYYY-MM-DD" (use it for the header date).
   - `lastPriority` — the previously captured snapshot (`{ capturedAt, body }`)
     or null on the first run. Use it in the commentary to note what slipped.
   If `briefing` errors (app not ready), say so in one line and stop.

2. **Drop what's done.** `today` rows with `resolvedToday: true` are already
   complete — use them ONLY to keep finished work out of the ranking. Do **not**
   list them; this snapshot is about what's left, not a log of what got done.

3. **Rank the open work.** Order the open `today` rows (`resolvedToday: false`,
   excluding reminders) most-actionable first. Weigh:
   - **In-flight first** — a started/in-review issue (`source: "linear"`) is the
     highest-priority work to finish.
   - **Deadline pressure** — fold in `upcoming`: due tomorrow or early next week
     outranks an undated item.
   - **Manual intent** — within a list, a lower `position` is the user's own
     higher ranking; respect it as a tiebreaker.
   - **Quick wins** — a small unblocked item can rank up as an easy clear.
   Treat a `today` row whose `source` is `linear` as the SAME work as its issue
   (match on `externalID`) — never list it twice.

4. **Compose the block — this is the deliverable.** Keep it tight and scannable;
   it renders in a narrow monospaced popover. Rules:
   - **Bullets, never paragraphs.** Short lines (aim ≤ 56 chars). Never write a
     line that would wrap.
   - **Lead with the priorities**, top first. Each is a one-line headline with a
     leading emoji for pop, then 1–2 short sub-bullets of *why* it matters — the
     deadline, the blocker, the payoff. Context, not item state.
   - **Lean on emoji** as visual anchors: 🔴 / 🟠 / 🟡 urgency · ⏰ deadline ·
     🚀 quick win · ⭐ carried-over · 🚧 blocked · 📌 reminder.
   - **Close with commentary** — a 💬 line or two: the one thing to nail, what
     slipped (from `lastPriority`), what can wait. Terse — no wrapping paragraph.
   - **Leave out** a "done today" tally and any per-item status dump.

   The example below is illustrative only — invent nothing; build the block from
   the actual `briefing` data. Adapt the shape, drop empty sections, keep every
   line short:

   ```
   🎯 Priorities · <Day Mon D>

   🔴 <Top priority, one line>
      ⏰ <why — a deadline or time pressure>
      🚧 <why — a blocker, if any>
   🚀 <Quick win, one line>
      • <why it's a fast clear>
   ⭐ <Carried-over item, one line>
      • <the next concrete step>
   🟡 <Lower-priority item, one line>
      • <one-line context>

   📌 <A reminder, if any>

   💬 <The one thing to nail today, and why.>
   💬 <What comes next, or what can wait.>
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

The "Priority capture" task does this on a schedule; when run that way, do the
work in a background subagent so the main session stays quiet. When the user
invokes the skill directly for a progress check, just produce the block — only
record it if they ask to pin or refresh it.

## Notes

- The output is just the block. No preamble ("here's your snapshot…"), no
  closing recap beyond the 💬 commentary, and **never** mention where the data
  comes from — not "local", not the item source, not "from your items." The data
  origin is irrelevant to the reader.
- Reasoning over `assist-ant briefing` alone (never the MCP or network) is a
  behavior of this skill, not something to surface in the output.
- Reminders are day-level: at most one short 📌 line, never with a time, and
  never inside the ranked priorities.
- Be terse. Short lines beat complete sentences; this lives in a narrow popover.
- Run `assist-ant briefing --help` or `assist-ant priority --help` if unsure of a
  flag rather than assuming.
