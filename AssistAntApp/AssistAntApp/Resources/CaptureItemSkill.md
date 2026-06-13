---
name: assist-ant-capture-item
description: Turn a captured note into a local AssistAnt item (to-do, reminder, or explore), resolving any day mentioned in the text, routing to the Icebox when asked, and following any public URL to enrich the description. Invoked by Quick Capture with the kind and the captured text.
---

# Capture an item into AssistAnt

You are given a **kind** (`todo`, `reminder`, or `explore`) and a short
**captured text**. Turn it into one item via `assist-ant actionable-item
create`. The CLI persists deterministically; your job is the interpretation the
CLI can't do — resolving a date, deciding Today vs Icebox, following a URL, and
composing a clean title + markdown body.

## Procedure

1. **Title.** Derive a concise one-line title from the capture (imperative for
   to-dos: "Pick up laundry"). Fall back to the first line if it's already
   short.

2. **Schedule.** If the text names a day or date ("tomorrow", "Friday",
   "June 20", "next week"), resolve it to `YYYY-MM-DD` in **America/Chicago**
   relative to today (run `date +%Y-%m-%d` to anchor "today" if unsure) and pass
   `--scheduled-on`. If it names a *time* too, keep only the date — items have
   no remind-at time. If no day is mentioned, **omit `--scheduled-on`** (the
   item is unscheduled and shows on Today by default).

3. **Icebox.** If the prompt says to stash it rather than do it now — "put it in
   the icebox", "backlog this", "for later", "someday", "not now" — pass
   `--icebox`. The item goes to the Icebox instead of Today. Icebox items are
   usually unscheduled; only also pass `--scheduled-on` if the prompt names a
   day too.

4. **Enrich URLs.** Scan the capture for URLs. For the **first one or two**, use
   **WebFetch** to read the page; if it's public (not paywalled / not
   login-walled), append a concise Markdown section to the body — the page
   title as a heading, 3–5 bullets of what it covers, and the link. Skip a URL
   that fails or is gated, noting it in one line. This matters most for
   `explore` captures. Pass the primary URL as `--url`.

5. **Compose the body.** Start with the original capture as Markdown, then the
   enrichment section(s). Write it to a temp file with the Write tool (e.g.
   `/tmp/aa-capture-<something>.md`); note the path.

6. **Create.** One command:

   ```bash
   assist-ant actionable-item create \
     --kind <todo|reminder|explore> \
     --title '<title>' \
     [--scheduled-on YYYY-MM-DD] \
     [--icebox] \
     [--url '<primary url>'] \
     --body-file '<path to the body file>'
   ```

7. **Report.** Relay the CLI's one-line summary. Keep it terse.

## Notes

- The CLI persists the item `source=manual`. By default it's unscheduled and
  non-iceboxed, so it lands on Today; `--scheduled-on` gives it a day and
  `--icebox` routes it to the Icebox instead. The user reschedules or moves it
  later from the UI.
- Do not invent a schedule or icebox a thing on your own. Only set
  `--scheduled-on` when the text names a day, and only set `--icebox` when the
  text asks to stash it.
- Run `assist-ant actionable-item create --help` if you need the flag list.
