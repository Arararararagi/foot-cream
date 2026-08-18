-- Footcream EPUB metric converter — pure Lua, no python3.
--
-- Rewrites an EPUB's html/xhtml chapters in place (imperial → metric), keeping a
-- byte-exact backup of the original epub for a safe revert. Uses KOReader's
-- bundled libarchive (ffi/archiver), so it runs on-device (Kobo, Kindle, …)
-- where there is no Python interpreter. Replaces metric_epub.py.
--
--   M.apply(epub_path, record_path, reps)  -> "OK:<n>" | "OK:0" | "ERROR:<msg>"
--   M.revert(epub_path, record_path)       -> "OK"     | "ERROR:<msg>"
--
-- reps: array of { from = "...", to = "...", guard_next = { "...", ... } }.
-- guard_next (optional) suppresses a replacement when the match is immediately
-- followed by one of those idiom words — e.g. "one foot in front of the other"
-- must not convert like the measurement "one foot deep".

local Archiver = require("ffi/archiver")
local lfs      = require("libs/libkoreader-lfs")

local M = {}

local HTML_EXTS = { xhtml = true, html = true, htm = true }

-- Is this zip entry an (X)HTML document we should rewrite? A recognised
-- extension is the fast path; otherwise sniff the content for an <html> root.
-- The sniff is essential because some tools name chapters in ways the extension
-- check misses — e.g. Calibre's split output "chapter.html_split_000" (ends in
-- digits, so `%.([%a]+)$` yields ""), which made whole books silently convert
-- nothing (OK:0). Sniffing safely skips css/opf/ncx/images — none contain "<html".
local function is_html(name, data)
    local ext = (name:match("%.([%a]+)$") or ""):lower()
    if HTML_EXTS[ext] then return true end
    if data then
        local head = data:sub(1, 2048):lower()
        return head:find("<html", 1, true) ~= nil
            or head:find("<!doctype html", 1, true) ~= nil
    end
    return false
end

local function file_exists(p)
    local f = p and io.open(p, "rb")
    if f then f:close(); return true end
    return false
end

local function copy_file(src, dst)
    local fi = io.open(src, "rb")
    if not fi then return false end
    local data = fi:read("*a")
    fi:close()
    local fo = io.open(dst, "wb")
    if not fo then return false end
    fo:write(data)
    fo:close()
    return true
end

-- Whole-file byte comparison (used by revert to detect a stale record whose
-- apply never actually modified the book).
local function files_identical(a, b)
    local fa = io.open(a, "rb"); if not fa then return false end
    local fb = io.open(b, "rb"); if not fb then fa:close(); return false end
    local da = fa:read("*a"); fa:close()
    local db = fb:read("*a"); fb:close()
    return da == db
end

-- ── entity-encoded fallback ───────────────────────────────────────────────────
-- Some epubs store non-ASCII punctuation (°, ′, ″, ', ", ×, dashes) as numeric
-- character references in the markup, even though crengine decodes them before
-- the scanner sees the text. A "from" built from the decoded text (e.g. "98°F")
-- then never matches the raw markup ("98&#xB0;F"). Build an entity-encoded
-- variant: any codepoint > 0x7E (or ' ") becomes &#xHEX;. Iterates UTF-8
-- codepoints, not bytes, so the hex value is the real codepoint.
local function entity_variant(s)
    local out, has_special = {}, false
    local i, n = 1, #s
    while i <= n do
        local b = s:byte(i)
        local cp, len
        if     b < 0x80 then cp, len = b, 1
        elseif b >= 0xF0 then cp, len = b % 0x08, 4
        elseif b >= 0xE0 then cp, len = b % 0x10, 3
        elseif b >= 0xC0 then cp, len = b % 0x20, 2
        else cp, len = b, 1 end  -- stray continuation byte; pass through
        for k = 1, len - 1 do
            cp = cp * 0x40 + ((s:byte(i + k) or 0) % 0x40)
        end
        local ch = s:sub(i, i + len - 1)
        if cp > 0x7E or ch == "'" or ch == '"' then
            out[#out + 1] = string.format("&#x%X;", cp)
            has_special = true
        else
            out[#out + 1] = ch
        end
        i = i + len
    end
    return table.concat(out), has_special
end

-- ── guarded flexible-whitespace replacement ───────────────────────────────────
local LUA_MAGIC = "[%(%)%.%%%+%-%*%?%[%]%^%$]"
local function esc(s) return (s:gsub(LUA_MAGIC, "%%%0")) end

-- Lua pattern matching `src` with whitespace runs collapsed to %s+, so a phrase
-- split across a line break in the markup ("1,800\nfeet") still matches.
local function build_pat(src)
    local parts = {}
    for piece in src:gmatch("%S+") do parts[#parts + 1] = esc(piece) end
    return table.concat(parts, "%s+")
end

-- Replace every match of `src` with `dst` in `text`, except where a guard word
-- follows. Returns (new_text, n_replaced).
local function replace_one(text, src, dst, guards)
    local pat = build_pat(src)
    if pat == "" then return text, 0 end
    local out, pos, count = {}, 1, 0
    while true do
        local s, e = text:find(pat, pos)
        if not s then break end
        local skip = false
        if guards then
            local after = text:sub(e + 1)
            for _, g in ipairs(guards) do
                local m = after:match("^(%s*" .. build_pat(g) .. ")")
                if m then
                    local nxt = after:sub(#m + 1, #m + 1)
                    if nxt == "" or not nxt:match("[%w]") then skip = true; break end
                end
            end
        end
        out[#out + 1] = text:sub(pos, s - 1)
        if skip then
            out[#out + 1] = text:sub(s, e)
        else
            out[#out + 1] = dst
            count = count + 1
        end
        pos = e + 1
    end
    out[#out + 1] = text:sub(pos)
    return table.concat(out), count
end

-- Try the decoded form, then the entity-encoded fallback.
local function apply_one(text, src, dst, guards)
    local new, n = replace_one(text, src, dst, guards)
    if n > 0 then return new, n end
    local src_ent, has_special = entity_variant(src)
    if has_special then
        new, n = replace_one(text, src_ent, dst, guards)
        if n > 0 then return new, n end
    end
    return text, 0
end

-- Count the post-guard occurrences of `src` in `text` (the number of
-- replacements apply_one WOULD make), trying the decoded form then the
-- entity-encoded fallback. Used by the homonym (currency/weight) guard.
local function count_one(text, src, guards)
    local _, n = replace_one(text, src, "", guards)
    if n > 0 then return n end
    local src_ent, has_special = entity_variant(src)
    if has_special then
        local _, n2 = replace_one(text, src_ent, "", guards)
        return n2
    end
    return 0
end

-- ── record (backup pointer) file ──────────────────────────────────────────────
local function write_record(path, rec)
    local f = io.open(path, "w")
    if not f then return false end
    f:write("return {\n")
    f:write(string.format("  backup = %q,\n", rec.backup))
    if rec.size then f:write(string.format("  size = %d,\n", rec.size)) end
    f:write("  files = {\n")
    for _, name in ipairs(rec.files or {}) do
        f:write(string.format("    %q,\n", name))
    end
    f:write("  },\n}\n")
    f:close()
    return true
end

local function read_record(path)
    local chunk = loadfile(path)
    if not chunk then return nil end
    local ok, rec = pcall(chunk)
    if ok and type(rec) == "table" then return rec end
    return nil
end

local function json_decode(s)
    local ok, rj = pcall(require, "rapidjson")
    if ok and rj and rj.decode then
        local ok2, t = pcall(rj.decode, s)
        if ok2 then return t end
    end
    local ok3, J = pcall(require, "json")  -- fallback if rapidjson is unavailable
    if ok3 and J and J.decode then
        local ok4, t = pcall(J.decode, s)
        if ok4 then return t end
    end
    return nil
end

-- Legacy record: builds before the current backup-based format stored a JSON
-- array of per-file string edits — [{file=.., patches={{from,to},..}}, ..] — and
-- did in-place text replacement with NO whole-file backup. read_record (loadfile)
-- can't parse JSON, so such a book errors "no patch record found" on every open.
-- Detect that shape here so revert can reverse-apply the edits (to -> from).
local function read_legacy_record(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = f:read("*a"); f:close()
    if not data or data == "" then return nil end
    local t = json_decode(data)
    if type(t) ~= "table" or type(t[1]) ~= "table" or type(t[1].patches) ~= "table" then
        return nil
    end
    return t
end

-- ── apply ─────────────────────────────────────────────────────────────────────
-- Does any (X)HTML chapter contain a soft hyphen (U+00AD, raw or as an
-- entity)? The scanner needs to know BEFORE scanning: crengine's regex
-- findAllText returns shifted/missing hits on soft-hyphenated text, so such
-- books scan through the plain-search fallback instead. File-level detection
-- because no crengine text API exposes the character (context extraction
-- strips it, and the plain search path skips it for matching).
-- Does the conversion record still describe the file on disk? A completed
-- apply stores the converted epub's byte size; if the on-disk size differs,
-- the file was replaced externally (re-download, sync, regenerated test book)
-- and the record is ORPHANED — the book must not be treated as converted, and
-- the backup must not be restored into it. Returns false only on a proven
-- mismatch; a missing/size-less record (legacy or interrupted apply) returns
-- true so those keep their existing open-time handling.
function M.record_matches_file(epub_path, record_path)
    local rec = read_record(record_path)
    if not rec or not rec.size then return true end
    local attr = lfs.attributes(epub_path)
    return attr ~= nil and attr.size == rec.size
end

function M.has_soft_hyphens(epub_path)
    local reader = Archiver.Reader:new()
    if not reader:open(epub_path) then return false end
    for entry in reader:iterate() do
        if entry.mode == "file" then
            local data = reader:extractToMemory(entry.path)
            if data and is_html(entry.path, data) then
                if data:find("\194\173", 1, true)
                   or data:find("&shy;", 1, true)
                   or data:find("&#173;", 1, true)
                   or data:find("&#xad;", 1, true)
                   or data:find("&#xAD;", 1, true) then
                    reader:close()
                    return true
                end
            end
        end
    end
    reader:close()
    return false
end

-- Does this book contain height shorthand (6'2") or a °F/°C symbol anywhere?
--
-- Answers from the RAW FILE, in one pass over the archive. The plugin normally
-- answers this by asking crengine for the whole book's rendered text, which
-- costs 0.02s on an ordinary book — and 160 SECONDS on a soft-hyphen one, where
-- it was 98% of the entire scan (measured 2026-08-17). Such books therefore ran
-- every prime/°F pass unconditionally, ~14s of wasted work on the 73% of books
-- that contain no such notation at all.
--
-- CONSERVATIVE BY CONSTRUCTION. A wrong `false` here silently drops every height
-- and temperature conversion in the book, with no error anywhere — the same
-- silent-failure shape as the inert guards this project keeps finding. A wrong
-- `true` merely costs a few passes. So: an unreadable archive answers "yes to
-- everything", tags are stripped before testing (a mark can sit in its own
-- element: 6<span>'</span>), and entities are decoded (&#8242; &rsquo; &deg;)
-- because the rendered text this replaces has none.
local ENTITIES = {
    ["&quot;"] = '"', ["&apos;"] = "'", ["&rsquo;"] = "\226\128\153",
    ["&lsquo;"] = "\226\128\152", ["&rdquo;"] = "\226\128\157",
    ["&ldquo;"] = "\226\128\156", ["&deg;"] = "\194\176",
    ["&prime;"] = "\226\128\178", ["&Prime;"] = "\226\128\179",
}
local function decode_entities(s)
    s = s:gsub("&#(%d+);", function(n)
        n = tonumber(n)
        if not n then return nil end
        if n < 128 then return string.char(n) end
        if n < 2048 then
            return string.char(192 + math.floor(n / 64), 128 + (n % 64))
        end
        return string.char(224 + math.floor(n / 4096),
                           128 + (math.floor(n / 64) % 64), 128 + (n % 64))
    end)
    s = s:gsub("&#[xX](%x+);", function(h)
        local n = tonumber(h, 16)
        if not n then return nil end
        if n < 128 then return string.char(n) end
        if n < 2048 then
            return string.char(192 + math.floor(n / 64), 128 + (n % 64))
        end
        return string.char(224 + math.floor(n / 4096),
                           128 + (math.floor(n / 64) % 64), 128 + (n % 64))
    end)
    return (s:gsub("&%a+;", function(e) return ENTITIES[e] end))
end

local _PRIME_MARKS = {
    "'", '"', "\226\128\178", "\226\128\179", "\226\128\153", "\226\128\157",
}

function M.probe_notation(epub_path)
    local yes = { prime = true, degf = true, degc = true }
    local reader = Archiver.Reader:new()
    if not reader:open(epub_path) then return yes end
    local out = { prime = false, degf = false, degc = false }
    for entry in reader:iterate() do
        if entry.mode == "file" then
            local data = reader:extractToMemory(entry.path)
            if data and is_html(entry.path, data) then
                local text = decode_entities((data:gsub("<[^>]*>", "")))
                if not out.degf and text:find("\194\176F", 1, true) then
                    out.degf = true
                end
                if not out.degc and text:find("\194\176C", 1, true) then
                    out.degc = true
                end
                if not out.prime then
                    for _, mark in ipairs(_PRIME_MARKS) do
                        -- A DIGIT immediately before the mark: that is what the
                        -- rendered-text gate tested, and a bare apostrophe is in
                        -- every book ever written.
                        if text:find("%d" .. mark:gsub("%W", "%%%0")) then
                            out.prime = true
                            break
                        end
                    end
                end
                if out.prime and out.degf and out.degc then
                    reader:close()
                    return out
                end
            end
        end
    end
    reader:close()
    return out
end

-- Tags that end a word when crengine lays the page out. Everything not listed
-- is treated as inline, i.e. as fusing the text either side of it.
local BLOCK_TAGS = {
    p = true, div = true, br = true, li = true, ul = true, ol = true,
    td = true, tr = true, table = true, section = true, article = true,
    blockquote = true, figure = true, figcaption = true, hr = true,
    body = true, html = true, head = true, title = true, dt = true, dd = true,
    h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true,
}

-- Strip markup the way the renderer resolves it: block tags become a space,
-- inline tags disappear. One pass, deciding per tag, rather than one gsub per
-- tag name over the whole file.
local function strip_markup(data)
    local out = data:gsub("<(/?)%s*([%a][%w]*)[^>]*>", function(_slash, name)
        return BLOCK_TAGS[name:lower()] and " " or ""
    end)
    -- Comments, doctypes, processing instructions: never text, never a break.
    return (out:gsub("<[^>]*>", ""))
end

-- Does `alias` occur as a WORD, not merely as a substring?
--
-- This is the whole point of the gate. A plain substring test reports "mi",
-- "kn", "ft" and "pt" present in every English book ever written ("might",
-- "know", "after", "kept") — and those four are 44% of the scan's alias walk,
-- so a substring test can never skip the passes that actually cost anything.
--
-- The rule mirrors the scanner's own boundary check exactly: only a LETTER on
-- either side disqualifies. Digits must NOT, or the fused "6ft" form would be
-- gated away. ASCII %a deliberately — the scanner uses %a too, so a UTF-8
-- continuation byte counts as a boundary in both places, and the gate can never
-- be stricter than the thing it is gating.
local function word_present(text, alias)
    local n, pos = #alias, 1
    while true do
        local i = text:find(alias, pos, true)
        if not i then return false end
        local before = i > 1 and text:sub(i - 1, i - 1) or ""
        local after  = text:sub(i + n, i + n)
        if not before:match("%a") and not after:match("%a") then return true end
        pos = i + 1
    end
end

-- Which unit aliases appear ANYWHERE in this book?
--
-- The scan runs one plain findAllText per alias, and a pass costs a full walk
-- of the document whether or not it matches — 54 passes were 19.5s of a 37s
-- scan on a Kobo. A pass for an alias the book never contains is pure waste,
-- and this answers which those are from the raw archive, in one read.
--
-- Every decision here is deliberately biased toward saying YES, because the two
-- errors are not symmetric: a wrong "present" costs one pass, a wrong "absent"
-- silently loses conversions for the rest of that book's life.
--   * tags are removed rather than replaced by a space, so "mi<i>les</i>"
--     fuses to "miles" — the same thing crengine renders. Fusing can invent an
--     alias that isn't really there; that only costs a pass.
--   * entities are decoded and soft hyphens stripped, so "mi&shy;les" and
--     "&#109;iles" both read as "miles".
--   * both sides are lowercased, because the scan's own search is
--     case-insensitive.
--   * ANY failure returns nil, which the caller reads as "run every pass".
--
-- Returns a set keyed by the alias strings passed in, or nil.
function M.probe_aliases(epub_path, aliases)
    if not aliases or #aliases == 0 then return nil end
    local reader = Archiver.Reader:new()
    if not reader:open(epub_path) then return nil end
    local lower, found, remaining = {}, {}, #aliases
    for _, a in ipairs(aliases) do lower[a] = a:lower() end
    local saw_text = false
    for entry in reader:iterate() do
        if entry.mode == "file" then
            local data = reader:extractToMemory(entry.path)
            if data and is_html(entry.path, data) then
                -- Block-level tags SEPARATE words, inline tags FUSE them, which
                -- is what crengine renders: "<p>mi</p><p>les</p>" is two words,
                -- "mi<i>les</i>" is one. Getting this backwards either way
                -- invents a word boundary that isn't there or hides one that is.
                local text = strip_markup(data)
                text = decode_entities(text)
                -- Soft hyphens vanish, whitespace runs collapse — so "fl\noz"
                -- and "mi\194\173les" read the way the reader sees them.
                text = text:gsub("\194\173", ""):gsub("%s+", " "):lower()
                if #text > 0 then saw_text = true end
                for _, a in ipairs(aliases) do
                    if not found[a] and word_present(text, lower[a]) then
                        found[a] = true
                        remaining = remaining - 1
                    end
                end
                if remaining <= 0 then
                    reader:close()
                    return found
                end
            end
        end
    end
    reader:close()
    -- Sanity check on the EXTRACTION, not on the book. An EPUB we decoded
    -- wrongly (unexpected encoding, an archive read as empty) would report every
    -- alias absent and silently disable the entire scan. Any English book uses
    -- at least a few of these as real words, so a near-empty result means we
    -- failed to read it.
    if not saw_text or (#aliases - remaining) < 3 then return nil end
    return found
end

function M.apply(epub_path, record_path, reps, opts)
    if not reps or #reps == 0 then return "OK:0" end
    local append_mode = opts and opts.append

    -- Apply longest `from` first. A shorter phrase that is a substring of a
    -- longer one ("one inch" inside "five foot one inch") would otherwise, if
    -- applied first, convert the substring and leave the longer phrase unable to
    -- match — the cause of compound heights converting only their inches half.
    -- (Underline/tap mode is positional so it never hits this; this is the
    -- sequential-text-replacement equivalent of the scanner's longest-first rule.)
    table.sort(reps, function(a, b) return #a.from > #b.from end)

    -- Read every entry into memory, preserving order.
    local reader = Archiver.Reader:new()
    if not reader:open(epub_path) then return "ERROR:cannot open epub" end
    local order, content = {}, {}
    for entry in reader:iterate() do
        if entry.mode == "file" then
            local data = reader:extractToMemory(entry.path)
            if not data then reader:close(); return "ERROR:read failed: " .. tostring(entry.path) end
            order[#order + 1] = entry.path
            content[entry.path] = data
        end
    end
    reader:close()

    -- Homonym guard (currency/weight): a rep carrying `.expected` (the number
    -- of positions the scanner kept it as a genuine measurement) must not be
    -- applied if the book contains MORE textual occurrences than that — the
    -- extras were suppressed by the scanner as a different sense (sterling £).
    -- Count occurrences across ALL html entries first (the replacement is
    -- global, so the decision has to be too), then mark over-counted reps to
    -- skip. (Counting < expected is fine — markup/entity divergence just means
    -- the rewriter sees fewer; we never suppress in that direction.)
    for _, rep in ipairs(reps) do
        if rep.expected then
            local found = 0
            for _, name in ipairs(order) do
                if is_html(name, content[name]) then
                    found = found + count_one(content[name], rep.from, rep.guard_next)
                end
            end
            if found > rep.expected then rep.skip = true end
        end
    end

    -- Apply replacements to html/xhtml entries.
    local modified, changed = {}, {}
    for _, name in ipairs(order) do
        if is_html(name, content[name]) then
            local text, total = content[name], 0
            if append_mode then
                -- Append mode's `to` CONTAINS the original text, so a shorter
                -- rep applied later would re-match inside an earlier rep's
                -- already-glossed span ("six feet" inside "six feet four
                -- inches (1.93 m)" → a bogus second gloss). Longest-first
                -- ordering can't save it the way it does for replacement,
                -- where the matched text disappears. Two phases instead:
                -- phase 1 swaps each match for an opaque placeholder
                -- (longest-first, guards honored) that no later rep can see;
                -- phase 2 expands placeholders to the glossed text.
                for i, rep in ipairs(reps) do
                    if not rep.skip then
                        local new, n = apply_one(text, rep.from,
                            "\1" .. i .. "\1", rep.guard_next)
                        if n > 0 then text = new; total = total + n end
                    end
                end
                if total > 0 then
                    for i, rep in ipairs(reps) do
                        if not rep.skip then
                            text = (text:gsub("\1" .. i .. "\1",
                                (rep.to:gsub("%%", "%%%%"))))
                        end
                    end
                end
            else
                for _, rep in ipairs(reps) do
                    if not rep.skip then
                        local new, n = apply_one(text, rep.from, rep.to, rep.guard_next)
                        if n > 0 then text = new; total = total + n end
                    end
                end
            end
            if total > 0 then
                modified[name] = text
                changed[#changed + 1] = name
            end
        end
    end
    if #changed == 0 then return "OK:0" end

    -- Fail fast (and cleanly) if we can't write next to the book — e.g. the
    -- containing folder is read-only to this user (a 9p/SMB share owned by
    -- another uid, as on the test VM's /mnt/macos/.../gutenberg/). Probe BEFORE
    -- creating any backup/record: otherwise we'd leave a stale "converted"
    -- record that makes every later open try (and fail) to auto-revert.
    local probe = epub_path .. ".footcream_wtest"
    local pf = io.open(probe, "wb")
    if not pf then return "ERROR:cannot convert — the book's folder is read-only" end
    pf:close(); os.remove(probe)

    -- Back up the original epub (whole-file, byte-exact) for revert.
    local backup_path = record_path .. ".orig"
    if not copy_file(epub_path, backup_path) then return "ERROR:cannot write backup" end

    -- Write the record FIRST (points at the backup; no size yet = "incomplete"),
    -- then the in-progress marker, so a crash mid-rewrite is recoverable: the
    -- plugin sees the marker on next open and auto-reverts from the backup.
    write_record(record_path, { backup = backup_path, files = changed })
    local marker = record_path .. ".inprogress"
    local mf = io.open(marker, "w"); if mf then mf:write("1"); mf:close() end

    -- Write the new epub: mimetype first and STORED, everything else deflated.
    local tmp = epub_path .. ".footcream_tmp"
    local writer = Archiver.Writer:new()
    if not writer:open(tmp, "epub") then
        -- Roll back the artifacts we just created so no stale "converted" record
        -- is left behind to break later opens.
        os.remove(marker); os.remove(backup_path); os.remove(record_path)
        return "ERROR:cannot open writer"
    end
    writer:setZipCompression("store")
    if content["mimetype"] then
        writer:addFileFromMemory("mimetype", content["mimetype"])
    end
    writer:setZipCompression("deflate")
    for _, name in ipairs(order) do
        if name ~= "mimetype" then
            writer:addFileFromMemory(name, modified[name] or content[name])
        end
    end
    writer:close()

    -- Atomic replace (rename over the open file is fine on Linux; the reader
    -- reloads afterwards and picks up the new inode).
    if not os.rename(tmp, epub_path) then
        os.remove(marker); os.remove(tmp)
        os.remove(backup_path); os.remove(record_path)
        return "ERROR:cannot replace epub"
    end

    -- Record the converted size for the revert external-change check, then clear
    -- the marker (apply complete).
    local attr = lfs.attributes(epub_path)
    write_record(record_path, {
        backup = backup_path, files = changed, size = attr and attr.size,
    })
    os.remove(marker)
    return "OK:" .. #changed
end

-- ── legacy revert (no backup — reverse-apply the recorded string edits) ─────────
-- For books converted by an old build that stored per-file {from,to} edits and no
-- whole-file backup. Rebuild the original by replacing each metric `to` back with
-- its imperial `from`. The `to` strings are highly distinctive ("10.2 cm (Four
-- inches)"), so reverse matching is unambiguous; reuses apply_one for the same
-- whitespace-flex + entity-encoded fallbacks the forward pass used.
local function revert_legacy(epub_path, record_path, legacy)
    local reps = {}
    for _, entry in ipairs(legacy) do
        for _, p in ipairs(entry.patches or {}) do
            if p.from and p.to then reps[#reps + 1] = { from = p.to, to = p.from } end
        end
    end
    if #reps == 0 then return "ERROR:no patch record found" end
    -- Longest metric string first, so one that is a substring of another (a bare
    -- "1.8 m" inside "1.8 m (six-foot)") reverts in the right order.
    table.sort(reps, function(a, b) return #a.from > #b.from end)

    local reader = Archiver.Reader:new()
    if not reader:open(epub_path) then return "ERROR:cannot open epub" end
    local order, content = {}, {}
    for entry in reader:iterate() do
        if entry.mode == "file" then
            local d = reader:extractToMemory(entry.path)
            if not d then reader:close(); return "ERROR:read failed: " .. tostring(entry.path) end
            order[#order + 1] = entry.path
            content[entry.path] = d
        end
    end
    reader:close()

    local modified, changed = {}, {}
    for _, name in ipairs(order) do
        if is_html(name, content[name]) then
            local text, total = content[name], 0
            for _, rep in ipairs(reps) do
                local new, n = apply_one(text, rep.from, rep.to, nil)
                if n > 0 then text = new; total = total + n end
            end
            if total > 0 then modified[name] = text; changed[#changed + 1] = name end
        end
    end
    if #changed == 0 then
        -- Nothing matched — the book is already in its original form. Drop the
        -- stale record so it stops erroring (and re-reverting) on every open.
        os.remove(record_path); os.remove(record_path .. ".inprogress")
        return "OK"
    end

    local probe = epub_path .. ".footcream_wtest"
    local pf = io.open(probe, "wb")
    if not pf then return "ERROR:cannot restore — the book's folder is read-only" end
    pf:close(); os.remove(probe)

    local tmp = epub_path .. ".footcream_tmp"
    local writer = Archiver.Writer:new()
    if not writer:open(tmp, "epub") then return "ERROR:cannot open writer" end
    writer:setZipCompression("store")
    if content["mimetype"] then writer:addFileFromMemory("mimetype", content["mimetype"]) end
    writer:setZipCompression("deflate")
    for _, name in ipairs(order) do
        if name ~= "mimetype" then
            writer:addFileFromMemory(name, modified[name] or content[name])
        end
    end
    writer:close()
    if not os.rename(tmp, epub_path) then os.remove(tmp); return "ERROR:cannot replace epub" end

    os.remove(record_path); os.remove(record_path .. ".inprogress")
    return "OK"
end

-- ── revert ────────────────────────────────────────────────────────────────────
function M.revert(epub_path, record_path)
    local rec = read_record(record_path)
    if not rec then
        -- Not the current Lua record — maybe a legacy JSON edit-list (no backup).
        local legacy = read_legacy_record(record_path)
        if legacy then return revert_legacy(epub_path, record_path, legacy) end
        return "ERROR:no patch record found"
    end
    local backup = rec.backup
    if not file_exists(backup) then return "ERROR:no patch record found" end

    -- External-change safety: a completed apply recorded the converted file
    -- size. If the on-disk epub no longer matches it, the file was replaced
    -- externally (e.g. a re-download of a different edition under the same
    -- name) — restoring our backup would clobber the user's new file. Refuse.
    -- (No recorded size = an interrupted apply; just restore the original.)
    if rec.size then
        local attr = lfs.attributes(epub_path)
        if not attr or attr.size ~= rec.size then
            return "ERROR:file changed since conversion — refusing to revert"
        end
    end

    local tmp = epub_path .. ".footcream_tmp"
    if not copy_file(backup, tmp) then
        -- Can't stage the restore (folder read-only?). If the on-disk epub is
        -- already byte-identical to the backup, the apply never actually
        -- modified it — this is a stale record from a half-failed apply. Clear
        -- it and report success so the book opens normally instead of erroring
        -- on every open.
        if files_identical(epub_path, backup) then
            os.remove(backup); os.remove(record_path)
            os.remove(record_path .. ".inprogress")
            return "OK"
        end
        return "ERROR:cannot stage restore"
    end
    if not os.rename(tmp, epub_path) then os.remove(tmp); return "ERROR:cannot replace epub" end

    os.remove(backup)
    os.remove(record_path)
    os.remove(record_path .. ".inprogress")
    return "OK"
end

return M
