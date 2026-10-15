# Bhagavad Gita reflections

The Home card replaces the former prayer-time panel. It works offline and needs
neither location nor a provider account. Settings › Bhagavad Gita enables it in
both normal Home and Exam week; the hover chip opens Home.

One reflection is selected for each local civil date. It changes at midnight,
including on daylight-saving days, and refreshes after wake and system clock or
time-zone changes. Next browses the collection; Today restores the daily selection.
Copy includes both the reference and the word “paraphrase.” Read verse opens the
corresponding source page in the default browser.

## Wording and references

The eight English texts in `GitaQuotes.swift` are original short paraphrases of
the verses, not verbatim quotations from a named modern translation. The card
labels them accordingly. They are not a substitute for the complete verses or
their devotional/philosophical context. In particular, the reflections retain
the spiritual context of yoga, the Divine and devotion rather than presenting
the work as only productivity advice.

References were checked against the verse text/translation published by Swami
Mukundananda. That edition's translation and commentary remain its publisher's
copyright; they are not bundled in this app. Each source link provides the full
verse and commentary:

- [2.47 — Action and its fruits](https://www.holy-bhagavad-gita.org/chapter/2/verse/47/)
- [2.48 — Evenness in success and failure](https://www.holy-bhagavad-gita.org/chapter/2/verse/48/)
- [4.39 — Faith, discipline, wisdom and peace](https://www.holy-bhagavad-gita.org/chapter/4/verse/39/)
- [6.5 — The mind as ally or adversary](https://www.holy-bhagavad-gita.org/chapter/6/verse/5/)
- [6.17 — Moderation and yoga](https://www.holy-bhagavad-gita.org/chapter/6/verse/17/)
- [6.26 — Returning the wandering mind](https://www.holy-bhagavad-gita.org/chapter/6/verse/26/)
- [12.13–14 — Compassion and devotion](https://www.holy-bhagavad-gita.org/chapter/12/verse/13-14/)
- [17.15 — Discipline of speech](https://www.holy-bhagavad-gita.org/chapter/17/verse/15/)

## Removed behavior

The prayer tracker/calculator, prayer reminders, Friday reminders, Qibla/Hijri UI
and prayer settings are removed. Historical changelog entries remain as release
history. Existing preference keys from the old feature are unused; the app does
not delete a user's past preferences. Location access remains available only for
optional weather. Old screenshots showing the removed UI are no longer linked
from the README; new native captures can be generated with the snapshot flags.

## Validation

Core checks cover known daily selections, wraparound, dates before the selection
epoch, both daylight-saving transitions, different local dates at the same instant,
unique references, source URLs and copied attribution. The macOS workflow builds
the app and runs core, bridge, approval and fake Codex transport checks without
requiring sign-in to a provider. It does not exercise camera, account sign-in or
the live visual layout.
