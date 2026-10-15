# Bhagavad Gita reflections

The Home card replaces the former prayer-time panel. It works offline and needs
neither location nor a provider account. Settings › Bhagavad Gita enables it in
both normal Home and Exam week; the hover chip opens Home.

One reflection is selected for each local civil date. It changes at midnight,
including on daylight-saving days, and refreshes after wake and system clock or
time-zone changes. Next browses the collection; Today restores the daily selection.
Copy includes the reference, excerpt label and translator attribution. The source
button opens the corresponding chapter of the translation in the default browser.

## Wording and references

The eight quotations are excerpts from Edwin Arnold's *The Song Celestial*, first
published in 1885. This is a public-domain English verse translation of the
Bhagavad Gita. Text, punctuation and poetic line breaks follow the linked edition;
these are short excerpts, not necessarily complete verses. The card and copied
text identify the translator and label each selection as an excerpt.

The [source edition](https://www.gutenberg.org/ebooks/2388) identifies Edwin Arnold
as translator and lists the work as public domain in the USA. Each card links to
the relevant chapter of its full text. Verse references identify the corresponding
Sanskrit passages; Arnold's poetic rendering does not print verse numbers.

| Reference | Subject | Translation chapter |
| --- | --- | --- |
| 2.47 | Action and its fruits | [II](https://www.gutenberg.org/cache/epub/2388/pg2388-images.html#chap02) |
| 2.48 | Action as spiritual practice | [II](https://www.gutenberg.org/cache/epub/2388/pg2388-images.html#chap02) |
| 4.39 | Faith, knowledge and peace | [IV](https://www.gutenberg.org/cache/epub/2388/pg2388-images.html#chap04) |
| 6.5 | The Self as friend or foe | [VI](https://www.gutenberg.org/cache/epub/2388/pg2388-images.html#chap06) |
| 6.17 | Moderation | [VI](https://www.gutenberg.org/cache/epub/2388/pg2388-images.html#chap06) |
| 6.26 | Returning the wandering mind | [VI](https://www.gutenberg.org/cache/epub/2388/pg2388-images.html#chap06) |
| 12.13 | Compassion and freedom from ego | [XII](https://www.gutenberg.org/cache/epub/2388/pg2388-images.html#chap12) |
| 17.15 | Discipline of speech | [XVII](https://www.gutenberg.org/cache/epub/2388/pg2388-images.html#chap17) |

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
