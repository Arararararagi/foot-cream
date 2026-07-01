## What is Footcream?

![Footcream](https://github.com/Fank1/foot-cream/releases/download/readme-assets/hero-img.png)

Are you tired of mentally trying to convert *"six foot four"* or *"ninety degrees Fahrenheit" *while reading English books? The Footcream plugin for KOReader scans your book once, finds every imperial measurement and gives you the metric value. You can choose to **underline** each one so you can **tap for the conversion**, or choose to **rewrite the text in place** so the metric value is just *there* as you read.

It's built to be smart about context. It knows the difference between pounds (the money) and pounds (the weight), between a six-foot man and a six-foot-by-eight-foot room, and it leaves idioms like *"stand on your own two feet"* alone.

It runs totally on-device (no API:s or Wifi needed). A novel takes about 15–30 seconds to scan (on an newer Kobo). The scan runs in the background, so you can read while it does it's magic.

DISCLAIMER: Although Claude Code helped a lot in the writing of Lua, I have QA:ed this plugin extensively with a large variety of content – so please don't judge it as bare slop before you tested it. Please give it a try - would love to hear the feedback!

***

## Features

- **2 reading modes**
  - **Underline & tap for metric**: non-destructive. Measurements get a distinct underline; tap one for a popup with the metric value.
  - **Convert directly in the text**: rewrites the book's text in place (e.g. *"six feet"* → *"1.8 m"*). Fully reversible.
- **Distinct highlight style**: plugin underlines never get confused with your own highlights.
- **Tap → popup** showing the metric conversion and a small unit icon.
- **Customisable styling** with a live preview: solid or wavy underline, intensity, thickness, tooltip size (S / M / L), optional unit icon. The styling dialog is draggable.
- **Per-category toggles**: turn whole groups (length, weight, volume, …) on or off.
- **UK / US aware**: uses imperial or US gallons & pints based on the book's language.
- **Smart Rounding** toggle clean, human-readable values instead of cluttery precision.
- **"Show original units"** option for *Convert directly in the text* mode — underlines the converted values and lets you tap to see the original imperial text.
- **Fast on reopen**: results are cached in a per-book sidecar; new books are scanned automatically.
- **Updateable**: check for and install updates from inside the plugin.
- **Reversible & per-book**: *"Remove Footcream data from this book"* undoes everything cleanly.

***

## Supported units

| Category        | Imperial                             | Metric         |
| --------------- | ------------------------------------ | -------------- |
| 📏 Length       | inch / inches                        | cm             |
| 📏 Length       | foot / feet / ft                     | m              |
| 📏 Length       | yard / yards / yd / yds              | m              |
| 📏 Length       | fathom / fathoms                     | m              |
| 📏 Length       | furlong / furlongs                   | m              |
| 📏 Length       | mile / miles / mi                    | km             |
| 📏 Length       | nautical mile / nmi                  | km             |
| 📏 Length       | league / leagues                     | km             |
| ⚖️ Weight       | ounce / ounces / oz                  | g              |
| ⚖️ Weight       | pound / pounds / lb / lbs            | kg             |
| ⚖️ Weight       | stone                                | kg             |
| 🧪 Volume       | fluid ounce / fl oz                  | mL             |
| 🧪 Volume       | pint / pints / pt                    | L              |
| 🧪 Volume       | quart / quarts / qt                  | L              |
| 🧪 Volume       | gallon / gallons / gal               | L              |
| 🌡️ Temperature | °F / degrees Fahrenheit              | °C             |
| 🚀 Speed        | mph / miles per hour / miles an hour | km/h           |
| 🚀 Speed        | knot / knots / kn                    | km/h           |
| 🟩 Area         | acre / acres                         | ha             |
| 🟩 Area         | square miles / feet / yards / …      | km² / m² / cm² |

*Volumes follow the book's locale — UK imperial vs. US measures.*

> **A note on tons:** Footcream intentionally does **not** convert *tons*. The word is ambiguous — a long ton (1016 kg), a short ton (907 kg), a metric tonne (1000 kg) etc. Rather than converting incorrectly, it leaves them untouched. If there is a huge need for this, it might be added in the future.

***

## Smart handling

Footcream isn't a dumb find-and-replace. A lot of the code goes into matching the right things and leaving the wrong things alone.

### Pounds: weight or money?

*"£"* and *"pounds"* are the same word for two different things, so Footcream weighs the surrounding context:

- **Weight cues**: *weighed, heavy, sack, crate, cargo, freight, boulder, overweight,* and nearby weight units (*stone, ounce*) push toward **weight** → converts to kg.
- **Currency cues**: *paid, cost, fortune, coins, salary,* and the **£** symbol push toward **money** → left alone.
- **Hard cues always win**: a *£* symbol, the word *sterling*, or coin denominations mark it as money no matter what else is around.
- **Magnitude prior**: a bare amount of *1000 pounds or more* with no weight cue is treated as currency (people rarely casually carry half a ton).

### Other smartness

- **UK vs. US volumes**: gallons and pints differ between the two; Footcream picks the right factor from the book's language.
- **Compound measurements**: heights like *"six foot four"*, *"5 ft 7 in"*, *"six-foot-five-inch"*, *"five-foot, seven inches"*, and *"six feet, one and a half inches"* are read as a single value. Same for weights: *"nine stone four"*, *"seven pounds four ounces"*.
- **Ranges**: *"four to five feet"*, *"twelve or fifteen miles"* convert to a metric range.
- **Fractions**: fractions *18½*), spelled-out fractions (*"two thirds of a mile"*, *"one and three-quarter leagues"*), and additive tails (*"two miles and a half"*).
- **Vague quantities** — *"a few hundred pounds"* becomes a range (*≈ 90–230 kg*) rather than a fake-precise number. Open for suggestions on how to improve this further.
- **Dimensions**: *"twenty feet by ten"* → *6 × 3 m*.
- **Smart rounding**: about two significant number, finer detail below a metre, whole numbers for vague distances.
- **Knows what to ignore**
  - *"stand on your own two feet"*, *"one inch at a time"*, *"a foot in the door"*
  - *Stone* as rock, *pints* in a pub when they're not a measurement
  - Screen sizes (a *15-inch* laptop stays a laptop)
  - Latitude/longitude coordinate marks
  - Chapter titles and headings are never converted

***

## The two modes

### Underline & tap for metric

Measurements are underlined in your chosen style. Tap one to see a popup with the metric value and a unit icon. Your book's text is never changed.

### Convert directly in the text

Footcream rewrites the measurements in the book's text itself. *"six feet"* becomes *"1.8 m"* as you read, no tapping required. Turn on **"Show original units"** (Advanced) to underline the converted values and tap any of them to see the original imperial text. This helps if you are worried something is not converted correctly. The book is fully reversible via *"Remove Footcream data from this book" *(Advanced).

***

## Styling

Open the styling dialog to customise how underlines and tooltips look, with a live preview.

![Styling dialog](https://github.com/Fank1/foot-cream/releases/download/readme-assets/styling.png)

***

## Installation

1. Download the latest `foot-cream.koplugin` release.
2. Copy the `foot-cream.koplugin` folder into your KOReader `plugins/` directory.
3. Restart KOReader.

You can check for updates via **Check for updates** in the plugin menu.

***

## Usage

1. Open a book in KOReader and go to **Settings** (Cogs) → **Footcream**. Either scan book-for-book or toggle the **Auto-scan** feature. It checks if the book is in English. It will leave other languages alone.
2. Pick a conversion mode and adjust styling and unit categories to taste from the menu.
3. Starting read Freedom Unit-free.

***

## How it works

Footcream scans the book's whole text once and stores the results in a small per-book sidecar file, so subsequent opens are instant. *Convert directly in the text* rewrites the book file's text. It's always reversible, but it *does* modify the stored book.

***

## Limitations

- *Tons* are intentionally unsupported (see the note above).
- Coverage supports English-language books only

***

## Contribution

- Fork and do your own thing with it or submit issues and I will update Footcream to become better over time.
- PRs will not really be prioritized, sorry.

### Flagging bad conversions

The best way to help is to flag conversions that come out wrong while you read. Footcream keeps a small on-device log of these so you can pull it off and attach it to a GitHub issue.

**How to flag:**

1. Open the Footcream menu → **Advanced** → **Debug** → **Units in book (list)**. This shows every measurement Footcream found in the current book.
2. **Long-press** the entry that's wrong. A dialog pops up. Pick the option that fits:
   - **⚑ Wrong conversion**: it converted, but the metric value is off.
   - **⚑ Missed / wrong span**: it grabbed too little/too much text, or missed part of the measurement.
   - **⚑ False positive**: it flagged something that isn't a measurement at all.
3. You'll see a "Flagged: …" confirmation. Each flag records the book title, what was detected, the value, the resulting conversion, the surrounding sentence, and its location in the book.

**Where the file lives:**

All flags are appended to a plain-text file at:

```text
koreader/footcream/flagged_errors.txt
```

(inside your KOReader data directory — e.g. on a Kobo, `.adds/koreader/footcream/flagged_errors.txt`). You can also review the log on-device via **Debug** → **View flagged errors**.

**Submitting it:**

1. Connect your reader to a computer over USB and copy `flagged_errors.txt` off the device.
2. Open a new issue in this repo and attach the file (or paste its contents). Feel free to add any extra context about what you expected.
3. Once you've submitted it, you can tidy up with **Debug** → **Clear flagged errors** to start a fresh log.
