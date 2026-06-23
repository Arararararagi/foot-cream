#!/usr/bin/env python3
"""
Footcream EPUB metric converter.

Usage:
  python3 metric_epub.py apply  <epub> <patches_file>  < replacements.json
  python3 metric_epub.py revert <epub> <patches_file>

For 'apply': reads JSON array from stdin:
  [{"from": "six feet", "to": "1.8 m", "guard_next": ["in front", "on"]}, ...]
The optional "guard_next" list suppresses a replacement when the matched text
is immediately followed by one of those words/phrases — used for body-part
idioms like "one foot in front of the other" that share surface text with a
real measurement ("one foot deep"). Without it the plain text replacement
would convert every "one foot" in the book, idiom or not.

Writes a patch record to <patches_file> so revert can undo. The record stores
each modified file's pre-edit bytes (for an exact revert) AND a hash of its
post-edit bytes (so revert can detect if the file was replaced externally
since the conversion and refuse, rather than corrupting an unrelated file).

Exit codes: 0 = success, 1 = error.
Prints "OK:<n_files_changed>" / "OK" or "ERROR:<message>" to stdout.
"""
import sys
import json
import zipfile
import io
import os
import re
import base64
import hashlib

HTML_EXTS = ('.xhtml', '.html', '.htm')


# Some EPUBs spell out non-ASCII punctuation (°, ′, ″, ', ", ×, dashes, ...)
# as numeric character references in the source markup, even though crengine
# decodes them before the scanner ever sees the text. A "from" string built
# from the decoded text (e.g. "98°F") then never matches the raw markup
# (e.g. "98&#xB0;F"), so the replacement is silently skipped. Build an
# entity-encoded fallback for any characters outside printable ASCII.
def _entity_variant(s):
    out = []
    has_special = False
    for ch in s:
        if ord(ch) > 0x7E or ch in "'\"":
            out.append(f'&#x{ord(ch):X};')
            has_special = True
        else:
            out.append(ch)
    return ''.join(out), has_special


def _build_regex(src, guard_next):
    """Compile a replacement pattern for `src`.

    - Whitespace in `src` is matched flexibly (`\\s+`) so a match split across
      a line break or run of spaces in the source markup — e.g. "1,800\\nfeet"
      — is still found and replaced (the scanner matches across these, the
      plain str.replace did not).
    - When `guard_next` is given, a negative lookahead prevents replacing an
      occurrence that is immediately followed by one of those idiom words.
    """
    esc = re.escape(src)
    # re.escape (Py3.7+) leaves spaces untouched but may prefix-escape other
    # whitespace; collapse any run of (optionally escaped) whitespace to \s+.
    esc = re.sub(r'(?:\\?\s)+', lambda m: r'\s+', esc)
    if guard_next:
        alts = '|'.join(re.escape(g) for g in guard_next)
        # Skip when followed (after optional space) by an idiom word/phrase.
        esc += r'(?!\s*(?:' + alts + r')\b)'
    return re.compile(esc)


def _apply_one(text, src, dst, guard_next):
    """Replace `src`→`dst` in `text`, trying the decoded form then an
    entity-encoded fallback. Returns (new_text, n_replacements, used_from)."""
    rx = _build_regex(src, guard_next)
    new, n = rx.subn(lambda m: dst, text)
    if n:
        return new, n, src
    src_ent, has_special = _entity_variant(src)
    if has_special:
        rx_ent = _build_regex(src_ent, guard_next)
        new, n = rx_ent.subn(lambda m: dst, text)
        if n:
            return new, n, src_ent
    return text, 0, None


def apply_metric(epub_path, patches_file, replacements):
    if not replacements:
        print("OK:0")
        return 0

    patch_record = []

    # Read the entire zip into memory so we can replace it atomically
    with zipfile.ZipFile(epub_path, 'r') as zin:
        infos = zin.infolist()
        contents = {info.filename: zin.read(info.filename) for info in infos}

    modified_files = {}
    for filename, raw in contents.items():
        if not any(filename.lower().endswith(ext) for ext in HTML_EXTS):
            continue
        try:
            text = raw.decode('utf-8')
        except UnicodeDecodeError:
            continue

        changed = text
        file_patches = []
        for rep in replacements:
            src, dst = rep['from'], rep['to']
            guard_next = rep.get('guard_next')
            changed, n, used_from = _apply_one(changed, src, dst, guard_next)
            if n:
                file_patches.append({'from': used_from, 'to': dst})

        if file_patches:
            new_bytes = changed.encode('utf-8')
            modified_files[filename] = new_bytes
            # Keep the pre-modification bytes so revert can restore them
            # byte-for-byte, rather than relying on reverse string-replacement
            # (which can drift if the converted text happens to already exist
            # elsewhere in the file). Also keep a hash of the post-edit bytes so
            # revert can verify the on-disk file is still the one we converted.
            patch_record.append({
                'file': filename,
                'original_b64': base64.b64encode(raw).decode('ascii'),
                'converted_sha256': hashlib.sha256(new_bytes).hexdigest(),
                'patches': file_patches,
            })

    if not modified_files:
        print("OK:0")
        return 0

    # Write the backup record FIRST (atomically), before touching the epub.
    # That way a crash can never leave the epub modified without a way back:
    # worst case is an orphaned patch record pointing at an unmodified epub,
    # and reverting that is a safe no-op (it restores identical bytes).
    patch_tmp = patches_file + '.footcream_tmp'
    with open(patch_tmp, 'w', encoding='utf-8') as f:
        json.dump(patch_record, f, ensure_ascii=False)
    os.replace(patch_tmp, patches_file)

    # Drop an "apply in progress" marker just before mutating the epub, and
    # remove it only on success. If the process is killed mid-apply, the marker
    # survives and the plugin auto-reverts (via original_b64) on next open
    # rather than silently leaving a half-converted book.
    marker = patches_file + '.inprogress'
    with open(marker, 'w', encoding='utf-8') as f:
        f.write('1')

    # Write new zip atomically via a BytesIO buffer then rename
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED, allowZip64=True) as zout:
        for info in infos:
            fname = info.filename
            if fname == 'mimetype':
                # Must be first and uncompressed per EPUB spec
                zi = zipfile.ZipInfo('mimetype')
                zout.writestr(zi, contents[fname], compress_type=zipfile.ZIP_STORED)
            elif fname in modified_files:
                zout.writestr(info, modified_files[fname])
            else:
                zout.writestr(info, contents[fname])

    tmp = epub_path + '.footcream_tmp'
    with open(tmp, 'wb') as f:
        f.write(buf.getvalue())
    os.replace(tmp, epub_path)

    # Apply finished cleanly — clear the in-progress marker.
    try:
        os.remove(marker)
    except OSError:
        pass

    print(f"OK:{len(modified_files)}")
    return 0


def revert_metric(epub_path, patches_file):
    if not os.path.exists(patches_file):
        print("ERROR:no patch record found")
        return 1

    with open(patches_file, encoding='utf-8') as f:
        patch_record = json.load(f)

    with zipfile.ZipFile(epub_path, 'r') as zin:
        infos = zin.infolist()
        contents = {info.filename: zin.read(info.filename) for info in infos}

    # Safety check: if a record carries the hash of the converted bytes we
    # wrote, the file on disk must still match it. If the epub was replaced
    # externally since conversion (e.g. a re-download or sync of a different
    # edition under the same filename), restoring our saved original bytes
    # would splice unrelated chapters into the new file — silent corruption.
    # Refuse rather than corrupt. (Legacy records without the hash skip this.)
    for entry in patch_record:
        want = entry.get('converted_sha256')
        if not want:
            continue
        fname = entry['file']
        cur = contents.get(fname)
        if cur is None or hashlib.sha256(cur).hexdigest() != want:
            print("ERROR:file changed since conversion — refusing to revert")
            return 1

    # Restore each modified file from its saved original bytes — byte-for-byte,
    # no string matching involved (so no risk of over/under-reverting).
    restored = {}
    for entry in patch_record:
        fname = entry['file']
        if 'original_b64' in entry:
            restored[fname] = base64.b64decode(entry['original_b64'])
        else:
            # Legacy patch record from before the backup-based format —
            # fall back to reverse string-replacement for this file only.
            raw = contents.get(fname)
            if raw is None:
                continue
            try:
                text = raw.decode('utf-8')
            except UnicodeDecodeError:
                continue
            for p in reversed(entry['patches']):
                text = text.replace(p['to'], p['from'])
            restored[fname] = text.encode('utf-8')

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED, allowZip64=True) as zout:
        for info in infos:
            fname = info.filename
            data = restored.get(fname, contents[fname])
            if fname == 'mimetype':
                zi = zipfile.ZipInfo('mimetype')
                zout.writestr(zi, data, compress_type=zipfile.ZIP_STORED)
            else:
                zout.writestr(info, data)

    tmp = epub_path + '.footcream_tmp'
    with open(tmp, 'wb') as f:
        f.write(buf.getvalue())
    os.replace(tmp, epub_path)

    os.remove(patches_file)
    # Clear any leftover in-progress marker from an interrupted apply.
    try:
        os.remove(patches_file + '.inprogress')
    except OSError:
        pass
    print("OK")
    return 0


if __name__ == '__main__':
    if len(sys.argv) < 4:
        print("ERROR:usage: metric_epub.py apply|revert <epub> <patches_file>")
        sys.exit(1)

    mode       = sys.argv[1]
    epub_path  = sys.argv[2]
    patches_file = sys.argv[3]

    if mode == 'apply':
        replacements = json.load(sys.stdin)
        sys.exit(apply_metric(epub_path, patches_file, replacements))
    elif mode == 'revert':
        sys.exit(revert_metric(epub_path, patches_file))
    else:
        print(f"ERROR:unknown mode {mode}")
        sys.exit(1)
