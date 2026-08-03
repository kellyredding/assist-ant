---
name: assist-ant-convert-scratch
description: Turn parked scratch notes into real AssistAnt items (to-do, reminder, or explore) — composing a title and a Markdown body for each, and following any public URL to enrich it. Invoked by the Scratch tab's convert gesture with the path to a JSON payload file holding the kind and the notes to convert.
---

# Convert scratch notes into AssistAnt items

You are invoked as `/assist-ant-convert-scratch <path>` with the path to a JSON
payload file. **First, read that file with the Read tool** — it holds
`{ "kind": "<todo|reminder|explore>", "items": [ { "id": "<id>", "text": "<the note>" }, … ] }`.
One note or twenty, the shape is the same and the **kind** applies to all of
them. Turn **each item into its own item** via `assist-ant scratch convert` —
one call per note. The CLI rewrites the note into a shaped item
deterministically; your job is the interpretation it can't do: inventing a real
title, shaping a raw note into a Markdown body, and following a URL.

A scratch note has **no title**. The pad stores a first-line excerpt only
because the column is NOT NULL, and it is not a title — never carry it over.
Compose one.

## Procedure

1. **Read the payload.** Take `kind` and the `items` list from it and work in
   that order. If the file is missing or won't parse, say so in one line and
   stop — there is nothing to convert and nothing to guess.

2. **Title, per item.** Compose a concise one-line title from the note
   (imperative for to-dos: "Renew the passport"). The note is raw — a pasted
   link, an id, half a sentence, three unrelated lines — so this is real work,
   not a truncation. For a bare URL, name what the page *is* once you've fetched
   it. Never emit the note's first line verbatim unless it genuinely reads as a
   title.

3. **Body, per item.** Start with the note as Markdown. Keep verbatim fragments
   verbatim — ids, paths, commands, code — in a fenced block, since parking a
   value intact is the whole point of the pad and stray `*` or `_` in prose
   would eat it. Add structure only where it clarifies; never invent facts,
   dates, or intent the note doesn't carry.

4. **Enrich URLs.** Scan each note for URLs. For the **first one or two**, use
   **WebFetch** to read the page; if it's public, append a concise Markdown
   section — the page title as a heading, 3–5 bullets of what it covers, and the
   link — and pass that link as `--url`. Skip a URL that fails or is gated,
   noting it in one line. This is the main reason conversion runs through you at
   all, and it matters most for `explore`. Different items are independent, so
   fetch for several in one message rather than one at a time.

5. **Write the body to a temp file** with the Write tool, **one file per item**
   named with the item id (e.g. `/tmp/aa-convert-<id>.md`), so a batch can't
   clobber its own bodies.

6. **Convert — one call per item:**

   ```bash
   assist-ant scratch convert \
     --id '<item id>' \
     --kind <todo|reminder|explore> \
     --title '<title>' \
     --body-file '<path to that item's body file>' \
     --url '<the link you followed, if any>'
   ```

   Never fold several ids into one call, and **never stop the run on a
   failure**: a non-zero exit converts nothing for that note and leaves it
   parked, which is exactly why each note gets its own call. Note what it said
   and move to the next item.

7. **Report every item, converted or not.** This is not optional bookkeeping —
   it is the only place a failure exists. The app shows no progress, no pending
   badge, and no timeout: a converted note simply leaves the scratch feed, and a
   failed one sits there looking untouched. Lead with the counts, then one line
   per note, and never report a total that hides a failure:

   ```
   Converted 3 of 4 notes to to-dos:
   ✓ Renew the passport
   ✓ Read the Swift 6 concurrency migration guide (enriched from swift.org)
   ✓ Call the dentist about the crown
   ✗ 019a…d4 — convert failed: only a scratch note can be converted
   ```

   Name a failed note by its id (its text may be long) and quote the CLI's
   reason. If every item failed, say so in the first line — don't bury it.

## Notes

- **`scratch convert` owns the whole transition.** It rewrites the note in place
  — same id, same capture time — so don't resolve or delete the note yourself,
  and don't reach for `actionable-item create`: that would mint a duplicate and
  leave the note parked.
- **The kind is already decided.** It came from the gesture the user made. Use
  the payload's kind for every item even when a note reads like a different one;
  re-deriving it would silently override an explicit choice.
- **If every item fails with "only a scratch note can be converted", suspect a
  duplicate invocation** — the app retypes an unconfirmed slash command, so this
  skill can legitimately run twice on one payload. The second run finds the
  notes already converted. Say that plainly rather than reporting a run of
  failures that never happened.
- **Convert sets no schedule and no list.** If a note names a day, keep it in
  the body and say so in the report; a follow-up `actionable-item update <id>`
  can schedule or list it if the user asks. Don't invent a schedule.
- **A title with an apostrophe breaks `'…'` quoting.** Use double quotes for
  that title instead.
- **Nothing is waiting on you** — no callback, no status, no deadline. Take the
  time to enrich properly. But nothing else tells the user either, which is what
  step 7 is for.
- The payload file and the body temp files are transient handoffs — you don't
  need to delete them.
- Run `assist-ant scratch convert --help` if you need the flag list rather than
  assuming.
