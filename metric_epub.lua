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

local function ext_of(name)
    return (name:match("%.([%a]+)$") or ""):lower()
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

-- ── apply ─────────────────────────────────────────────────────────────────────
function M.apply(epub_path, record_path, reps)
    if not reps or #reps == 0 then return "OK:0" end

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

    -- Apply replacements to html/xhtml entries.
    local modified, changed = {}, {}
    for _, name in ipairs(order) do
        if HTML_EXTS[ext_of(name)] then
            local text, total = content[name], 0
            for _, rep in ipairs(reps) do
                local new, n = apply_one(text, rep.from, rep.to, rep.guard_next)
                if n > 0 then text = new; total = total + n end
            end
            if total > 0 then
                modified[name] = text
                changed[#changed + 1] = name
            end
        end
    end
    if #changed == 0 then return "OK:0" end

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
        os.remove(marker); return "ERROR:cannot open writer"
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
        os.remove(marker); return "ERROR:cannot replace epub"
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

-- ── revert ────────────────────────────────────────────────────────────────────
function M.revert(epub_path, record_path)
    local rec = read_record(record_path)
    if not rec then return "ERROR:no patch record found" end
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
    if not copy_file(backup, tmp) then return "ERROR:cannot stage restore" end
    if not os.rename(tmp, epub_path) then return "ERROR:cannot replace epub" end

    os.remove(backup)
    os.remove(record_path)
    os.remove(record_path .. ".inprogress")
    return "OK"
end

return M
