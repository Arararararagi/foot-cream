# Helping with Footcream

Two ways to help, both small. Neither needs any programming.

1. **[Tell me when a conversion is wrong](#tell-me-when-a-conversion-is-wrong)** — a long-press while you read.
2. **[Fix the translations](#fix-the-translations)** — the rest of this page.

---

## Tell me when a conversion is wrong

This is the most useful thing you can do. While reading, long-press a
measurement Footcream got wrong and pick what's wrong with it. If Footcream
*missed* a measurement, select the text and choose **⚑ Flag to Footcream**.

Turn on **Advanced → "Long-press units to send errors to the developer"** and
those reports are sent anonymously. Each one contains the book title, the
measurement, its conversion, and the sentence around it — nothing else. It
works offline; reports are queued and sent when you reconnect.

Full details are in the [README](README.md#flagging-bad-conversions).

---

## Fix the translations

Footcream is translated here:

**https://crowdin.com/project/foot-cream**

Sign in, choose your language, and start typing. Nothing to install, no
programming, no files to send anywhere. Your work is collected automatically
and goes out with the next version.

### The translations you see were made by a computer. Please fix them

All 30 languages already have a first draft written by AI. Some of it is fine.
Some of it is stiff, and some of it is simply wrong.

That draft is there to save you time, not to be correct. Reading a sentence
and fixing it is much faster than writing 166 of them from nothing.

So: read a line, fix what sounds wrong, move on. **Even ten fixed lines are a
real help.** You don't have to finish anything.

If your language is missing, open an issue and it will be added.

### Start with the short texts

There are two sets:

- **labels** — 139 short texts: menus, buttons, messages. **Start here.**
- **help** — 27 long explanations that appear when you hold a menu item down.

The 27 long ones contain more than half of all the words, so they take far
longer than their number suggests. Doing only **labels** already makes
Footcream fully usable in your language. Anything you skip stays in English,
which is fine.

### Two things that make a translation feel native

- **Every text comes with a note** saying where it appears and what it does —
  which menu it's under, which dialog a button belongs to, or the sentence a
  fragment gets slotted into. Crowdin shows it above the editing box. Read it
  when a text is short or ambiguous. If a note is missing or unhelpful,
  that's worth reporting.
- **Match KOReader's own wording.** Footcream is a plugin, so it sits inside
  KOReader's menus. Footcream has its own separate translation project, which
  means common words ("Cancel", "Settings", "Close") won't be suggested to you
  from KOReader's existing work. Look at how KOReader says a word in your
  language and use the same one, so the plugin doesn't read as foreign inside
  it.

### Four things to be careful with

Everything else is your judgement. These four are not:

**1. Don't remove `%1` or `%2`.**
These are slots. Footcream drops a number or a word into them while you read,
so `Mode: %1` might appear as `Mode: Metric`. Keep them exactly as they are,
with no space after the `%`. You *can* move them to a different place in the
sentence if your language needs that — just don't delete them or invent new
ones. Crowdin warns you if one goes missing.

**2. Fill in every plural box.**
English has two forms (*1 unit*, *2 units*). Your language may need one, four,
or six. Crowdin shows you the right number of boxes and labels them for you.
Fill in all of them — even when two end up identical. In Turkish and Hungarian
that's correct, because the word doesn't change after a number.

**3. Watch for spaces at the start and end.**
A few texts are half-sentences that get joined together, like
`The hallway was ` + `1.8 m` + ` wide.` If your language puts the word "wide"
somewhere else, move the *word* but keep the *space*. Without it, two words
run together.

**4. Never translate the units.**
`m`, `km`, `kg`, `°C`, `km/h`, and examples like `5 ft 11 in` stay exactly as
they are in every language. So does the `.` in `1.8` — Footcream writes numbers
the same way everywhere, on purpose, and that is **not** a bug to report. It
briefly followed the interface language instead, and that put `1,8 m` into
paragraphs where the author had written `1.8`, so a single paragraph disagreed
with itself.

### What happens to your work

**Nobody has to approve it.** Footcream is a small plugin. Waiting for a second
speaker to check every language would mostly mean nothing ever gets released.
What you write goes out in the next version.

The only automatic checks are the four things above — the ones that would
actually break the screen. Nobody checks whether your wording sounds good.

That's worth saying out loud, because it's a real trade: **please don't paste
in machine translation you haven't read yourself.** A sentence that is
obviously wrong is worse for a reader than an English one. English at least
looks intentional.

If you spot a bad translation in a language that's already released, just fix
it. You don't need to ask.

---

Translations are contributed under Footcream's licence,
**AGPL-3.0-or-later** — the same one KOReader uses. That is what allows a
translation to ship inside the plugin.

Maintaining the translation pipeline itself (how `.po` files are built, synced
and mapped to directories) is documented separately in
[l10n/README.md](l10n/README.md). You don't need any of it to translate.
