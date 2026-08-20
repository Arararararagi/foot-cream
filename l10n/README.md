# Translation pipeline (maintainer notes)

**Translating Footcream? You don't need this file** — see
[CONTRIBUTING.md](../CONTRIBUTING.md), which is the whole job. This one covers
how the machinery works, and only matters if you're changing it.

Translations live in [Crowdin][crowdin-project]. Footcream is a KOReader
plugin, not part of KOReader, so it has its own project rather than riding on
[KOReader's][koreader-weblate] (KOReader uses Weblate; Footcream uses Crowdin).

## Files and who owns them

| Path | Owner | Notes |
|---|---|---|
| `templates/foot-cream.pot` | repo | Extracted from `main.lua` by `builder/build_l10n.sh`. Never hand-edit. |
| `templates/foot-cream-labels.pot`, `-help.pot` | repo | Split from the above by `builder/split_pot.py`. Also generated. |
| `<lang>/labels.po`, `<lang>/help.po` | **Crowdin** | The translations. See the warning below. |
| `<lang>/foot-cream.mo` | build | `msgcat` + `msgfmt` of both `.po`. Gitignored; rebuilt at release. |

`<lang>` uses KOReader's locale codes (`de`, `fr`, `pt_BR`, `zh_CN`), not
Crowdin's. That distinction is the single most dangerous thing here — see the
last section.

At runtime the plugin loads `l10n/<current language>/foot-cream.mo` and merges
it into KOReader's own translation table; see the comment above `_.loadMO(...)`
near the top of `main.lua`.

## Never hand-edit a .po in git

**Crowdin owns `l10n/<lang>/*.po`.** The integration runs with *"Always import
new translations from the repository"* OFF, so Crowdin does not read `.po`
changes made in git. A hand-edited `.po` — even one merged via pull request —
is silently overwritten by the next sync, and the contributor's work
disappears with no error anywhere.

If someone sends a translation as a pull request, don't merge it. Ask them to
submit it in Crowdin, or import it there yourself and let the sync write it
back.

The repo owns the other direction: the `.pot` templates are generated here, and
*"Push Sources"* is OFF so Crowdin can never overwrite them. Sources flow
repo → Crowdin, translations flow Crowdin → repo, and neither direction is
contested.

## Release flow

Crowdin commits to the `l10n_main` service branch continuously. It is merged
**only when a release is cut**, so nothing lands unreviewed mid-cycle:

```
rm -f l10n/*/labels.po l10n/*/help.po   # only if you generated any locally
git merge origin/l10n_main
./builder/check.sh                      # stages 7-9 cover the l10n side
./release.sh <version>
```

`release.sh` refuses to release while `l10n_main` is ahead and unmerged. If you
have generated `.po` locally (via `builder/make_po.py`), delete them before
merging or git will refuse to overwrite untracked files.

## Project settings that are not in crowdin.yml

`crowdin.yml` governs *file mapping* only. These are web-UI settings and are
invisible to the repo:

- **Skip untranslated strings — ON.** Without it Crowdin fills untranslated
  strings with the English source, so a language at 5% comes back looking
  complete and the `.po` stops being a usable progress signal. For gettext it
  omits them entirely, which is what the runtime's per-string fallback expects.
- **Export with N approvals — OFF.** Proofreading is enabled as a tool, but
  deliberately not as a ship gate; see CONTRIBUTING.md.
- **Push Sources — OFF**, **Always import new translations — OFF.** As above.
- Licence set to AGPL-3.0-or-later, matching the plugin.
- 58 target languages, set in one call by `builder/crowdin_set_languages.py`.

## Guards

- `builder/check.sh` stage 7 validates the `crowdin.yml` language mapping
  against Crowdin's real language list; stage 8 rejects an unknown
  `l10n/<dir>`; stage 9 (`check_po.py`) checks placeholders, plural-form count
  against each file's own header, unit symbols, edge spaces and `msgfmt -c`.
- `builder/verify_crowdin_sync.sh` checks the directory names Crowdin actually
  wrote.
- `builder/sync_locales.py` regenerates `LOCALES` from KOReader's translations
  submodule, so the list is never hand-maintained.

## Still to do

1. Apply for the free **open-source plan** at
   <https://crowdin.com/page/open-source-project-setup-request>. Their
   criterion is a repo at least 3 months old — this one qualifies from
   **2026-09-23**.
2. Add screenshots in Crowdin so translators see strings in place.

## Why the language mapping matters more than it looks

At runtime the plugin loads:

    l10n/<KOReader's gettext current_lang>/foot-cream.mo

so the directory name must be KOReader's code, not the platform's. Crowdin's
default `%locale_with_underscore%` produces `de_DE` where KOReader wants plain
`de`. Get it wrong and the catalogue is translated, compiled, shipped — and
never loaded. No error, no warning, just an English UI and a translator
wondering why their work vanished.

Worse, `crowdin.yml`'s `languages_mapping` keys must be Crowdin **language
IDs** (`de`, `es-ES`), *not* the directory you want emitted. Writing `de_DE:`
means Crowdin looks up `de`, misses, and silently falls back to its default.
That mistake once produced 22 wrong directories in a single sync. It is checked
mechanically in two places rather than trusted.

[crowdin-project]: https://crowdin.com/project/foot-cream
[koreader-weblate]: https://hosted.weblate.org/engage/koreader/
