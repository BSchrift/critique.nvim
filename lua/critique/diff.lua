-- Parses `git diff` output and draws GitHub-style overlays on buffers.
local M = {}
local xdiff = vim.text.diff or vim.diff -- renamed in nvim 0.12

-- Words (incl. UTF-8), whitespace runs, and single punctuation bytes.
local function tokenize(s)
  local toks, i = {}, 1
  while i <= #s do
    local j = s:match('^[%w_\128-\255]+()', i) or s:match('^%s+()', i) or i + 1
    toks[#toks + 1] = s:sub(i, j - 1)
    i = j
  end
  return toks
end

-- Changed byte ranges {start, end} (0-based, end exclusive) between two lines, by word.
function M.word_diff(a, b)
  if a == '' or b == '' then return {}, {} end -- no words to compare; also, zero tokens would still diff as one line
  local ta, tb = tokenize(a), tokenize(b)
  local function offsets(t)
    local o = { 0 }
    for i, s in ipairs(t) do o[i + 1] = o[i] + #s end
    return o
  end
  local oa, ob = offsets(ta), offsets(tb)
  local ra, rb, same = {}, {}, #a + #b
  local hunks = xdiff(table.concat(ta, '\n') .. '\n', table.concat(tb, '\n') .. '\n', { result_type = 'indices' })
  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = unpack(h)
    if ca > 0 then
      ra[#ra + 1] = { oa[sa], oa[sa + ca] }
      same = same - (oa[sa + ca] - oa[sa])
    end
    if cb > 0 then
      rb[#rb + 1] = { ob[sb], ob[sb + cb] }
      same = same - (ob[sb + cb] - ob[sb])
    end
  end
  -- Like GitHub, skip word highlights when the lines barely resemble each other.
  if same < (#a + #b) / 2 then return {}, {} end
  return ra, rb
end

-- shortcut: paths git quotes (control chars, quotes, backslashes) are not unquoted; unquote if anyone hits it.
function M.parse(text)
  local files, file, hunk, o, n = {}, nil, nil, 0, 0
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    local hs = { line:match('^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@') }
    if vim.startswith(line, 'diff --git ') then
      file = { status = 'M', hunks = {}, blocks = {}, anchor_left = {}, adds = 0, dels = 0 }
      file.old_path, file.path = line:match('^diff %-%-git a/(.-) b/(.*)$') -- fallback when there is no ---/+++
      files[#files + 1], hunk = file, nil
    elseif file and hs[1] then
      hunk = {
        old_start = tonumber(hs[1]), old_count = tonumber(hs[2]) or 1,
        new_start = tonumber(hs[3]), new_count = tonumber(hs[4]) or 1,
        lines = {},
      }
      file.hunks[#file.hunks + 1], o, n = hunk, hunk.old_start, hunk.new_start
    elseif hunk then
      local kind, s = line:sub(1, 1), line:sub(2)
      if kind == ' ' then
        hunk.lines[#hunk.lines + 1] = { kind = kind, text = s, old = o, new = n }
        o, n = o + 1, n + 1
      elseif kind == '-' then
        hunk.lines[#hunk.lines + 1] = { kind = kind, text = s, old = o }
        o, file.dels = o + 1, file.dels + 1
      elseif kind == '+' then
        hunk.lines[#hunk.lines + 1] = { kind = kind, text = s, new = n }
        n, file.adds = n + 1, file.adds + 1
      end -- '\ No newline at end of file' is ignored
    elseif file then
      if vim.startswith(line, 'new file') then file.status = 'A'
      elseif vim.startswith(line, 'deleted file') then file.status = 'D'
      elseif vim.startswith(line, 'rename from ') then file.status, file.old_path = 'R', line:sub(13)
      elseif vim.startswith(line, 'rename to ') then file.path = line:sub(11)
      elseif vim.startswith(line, '--- a/') then file.old_path = line:sub(7)
      elseif vim.startswith(line, '+++ b/') then file.path = line:sub(7)
      end
    end
  end

  -- Group each run of -/+ lines into a block, and pair them up for word highlights.
  for _, f in ipairs(files) do
    for _, h in ipairs(f.hunks) do
      local b
      o, n = h.old_start, h.new_start
      for _, l in ipairs(h.lines) do
        if l.kind == ' ' then
          b, f.anchor_left[l.old] = nil, l.new
        else
          if not b then
            b = { dels = {}, adds = {}, new = n, old = o }
            f.blocks[#f.blocks + 1] = b
          end
          table.insert(l.kind == '-' and b.dels or b.adds, l)
          if l.kind == '-' then f.anchor_left[l.old] = b.new end
        end
        o, n = o + (l.old and 1 or 0), n + (l.new and 1 or 0)
      end
    end
    for _, b in ipairs(f.blocks) do
      b.old_end = b.old + #b.dels
      for i = 1, math.min(#b.dels, #b.adds) do
        b.dels[i].words, b.adds[i].words = M.word_diff(b.dels[i].text, b.adds[i].text)
        b.dels[i].pair, b.adds[i].pair = b.adds[i], b.dels[i]
      end
    end
  end
  return files
end

-- Index of the hunk containing lnum on side ('LEFT' = base, 'RIGHT' = head), or nil.
function M.hunk_of(file, lnum, side)
  local k = side == 'LEFT' and 'old' or 'new'
  for i, h in ipairs(file.hunks) do
    if lnum >= h[k .. '_start'] and lnum < h[k .. '_start'] + h[k .. '_count'] then return i end
  end
end

-- First line of every change block on a side, for ]c / [c.
function M.stops(file, side)
  local k = side == 'LEFT' and 'old' or 'new'
  return vim.tbl_map(function(b) return b[k] end, file.blocks)
end

-- Map a line number from one version to the other ('old' <-> 'new').
function M.map_line(file, lnum, from, to)
  local out = lnum
  for _, h in ipairs(file.hunks) do
    local fs, fe = h[from .. '_start'], h[from .. '_start'] + h[from .. '_count']
    if lnum < fs then break end
    if lnum >= fe then
      out = lnum - fe + h[to .. '_start'] + h[to .. '_count']
    else
      local last = h[to .. '_start']
      for _, l in ipairs(h.lines) do
        if l[to] then last = l[to] end
        if l[from] == lnum then return l.pair and l.pair[to] or math.max(1, last) end
      end
    end
  end
  return math.max(1, out)
end

local function expand_tabs(s, col, ts)
  local out = {}
  for seg, tab in s:gmatch('([^\t]*)(\t?)') do
    out[#out + 1], col = seg, col + vim.fn.strdisplaywidth(seg)
    if tab ~= '' then
      local w = ts - col % ts
      out[#out + 1], col = (' '):rep(w), col + w
    end
  end
  return table.concat(out), col
end

-- One virtual line: the text with word highlights, padded so the background spans the window.
local function virt_line(l, hl, ts)
  local chunks, col, pos = {}, 0, 0
  local function push(s, e, group)
    if e <= s then return end
    local str
    str, col = expand_tabs(l.text:sub(s + 1, e), col, ts)
    chunks[#chunks + 1] = { str, group }
  end
  for _, r in ipairs(l.words or {}) do
    push(pos, r[1], hl)
    push(r[1], r[2], hl .. 'Word')
    pos = r[2]
  end
  push(pos, #l.text, hl)
  chunks[#chunks + 1] = { (' '):rep(500), hl }
  return chunks
end

-- The head (RIGHT) shows additions in place and deletions as virtual lines; the base (LEFT) the reverse.
local SIDES = {
  RIGHT = { mine = 'adds', other = 'dels', key = 'new', virt_at = 'new', hl = 'CritiqueAdd', other_hl = 'CritiqueDelete', sign = '+' },
  LEFT = { mine = 'dels', other = 'adds', key = 'old', virt_at = 'old_end', hl = 'CritiqueDelete', other_hl = 'CritiqueAdd', sign = '-' },
}

function M.render(buf, file, side, ns)
  local s, last, ts = SIDES[side], vim.api.nvim_buf_line_count(buf), vim.bo[buf].tabstop
  for _, b in ipairs(file.blocks) do
    for _, l in ipairs(b[s.mine]) do
      local row = math.min(l[s.key], last) - 1
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { line_hl_group = s.hl, sign_text = s.sign, sign_hl_group = s.hl .. 'Sign' })
      for _, r in ipairs(l.words or {}) do
        vim.api.nvim_buf_set_extmark(buf, ns, row, r[1], { end_col = r[2], hl_group = s.hl .. 'Word', strict = false })
      end
    end
    if #b[s.other] > 0 then
      local row = b[s.virt_at] - 1
      vim.api.nvim_buf_set_extmark(buf, ns, math.max(0, math.min(row, last - 1)), 0, {
        virt_lines = vim.tbl_map(function(l) return virt_line(l, s.other_hl, ts) end, b[s.other]),
        virt_lines_above = row < last,
        virt_lines_overflow = 'scroll',
      })
    end
  end
end

return M
