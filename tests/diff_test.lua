-- Unit tests for lua/critique/diff.lua. Run: nvim --headless -l tests/diff_test.lua
local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
local diff = require('critique.diff')

local files = diff.parse([[
diff --git a/a.lua b/a.lua
index 1111111..2222222 100644
--- a/a.lua
+++ b/a.lua
@@ -1,5 +1,5 @@
 local x = 1
-return x + 1
+return x + 2
 end
-gone
 keep
+added
diff --git a/b.txt b/b.txt
--- a/b.txt
+++ b/b.txt
@@ -1,3 +1,4 @@
+new first
 one
 two
 three
diff --git a/old name.txt b/new name.txt
similarity index 90%
rename from old name.txt
rename to new name.txt
--- a/old name.txt
+++ b/new name.txt
@@ -1 +1 @@
-hi
+hello
diff --git a/gone.txt b/gone.txt
deleted file mode 100644
--- a/gone.txt
+++ /dev/null
@@ -1,2 +0,0 @@
--- x
-b
diff --git a/img.png b/img.png
index 3333333..4444444 100644
Binary files a/img.png and b/img.png differ
diff --git a/script.sh b/script.sh
old mode 100644
new mode 100755
diff --git a/eof.txt b/eof.txt
--- a/eof.txt
+++ b/eof.txt
@@ -1 +1 @@
-no newline
\ No newline at end of file
+no newline
]])
local a, b, r, d, img, mode, eof = unpack(files)

H.section('parse')
H.test('finds every file', function()
  H.eq(vim.tbl_map(function(f) return f.status .. ' ' .. f.path end, files),
    { 'M a.lua', 'M b.txt', 'R new name.txt', 'D gone.txt', 'M img.png', 'M script.sh', 'M eof.txt' })
end)
H.test('counts additions and deletions', function()
  H.eq({ a.adds, a.dels, b.adds, b.dels, d.adds, d.dels }, { 2, 2, 1, 0, 0, 2 })
end)
H.test('groups changed lines into blocks', function()
  H.eq(vim.tbl_map(function(blk) return { blk.new, blk.old, blk.old_end, #blk.dels, #blk.adds } end, a.blocks),
    { { 2, 2, 3, 1, 1 }, { 4, 4, 5, 1, 0 }, { 5, 6, 6, 0, 1 } })
end)
H.test('maps old lines to where they show in the new version', function()
  H.eq(a.anchor_left, { 1, 2, 3, 4, 4 }, 'deleted line 4 shows above new line 4')
end)
H.test('renames keep both paths; a missing hunk count means 1', function()
  H.eq({ r.path, r.old_path, r.status, r.hunks[1].old_count, r.hunks[1].new_count }, { 'new name.txt', 'old name.txt', 'R', 1, 1 })
end)
H.test('deleted files keep their path and a removed line starting with "--"', function()
  H.eq({ d.path, d.status, d.blocks[1].dels[1].text, d.blocks[1].new }, { 'gone.txt', 'D', '-- x', 0 })
end)
H.test('binary and mode-only changes have no hunks', function()
  H.eq({ #img.hunks, #mode.hunks, mode.path }, { 0, 0, 'script.sh' })
end)
H.test('"\\ No newline at end of file" is not a line', function()
  H.eq(#eof.hunks[1].lines, 2)
end)
H.test('the shared git arguments use GitHub\'s settings', function()
  for _, arg in ipairs({ '-U3', '-M', '--diff-algorithm=myers', '--no-ext-diff', '--src-prefix=a/' }) do
    H.ok(vim.tbl_contains(diff.GIT_ARGS, arg), arg)
  end
end)

H.section('word_diff')
H.test('highlights only the changed word', function()
  H.eq(a.blocks[1].adds[1].words, { { 11, 12 } })
  H.eq(a.blocks[1].dels[1].words, { { 11, 12 } })
end)
H.test('several changed words give several ranges', function()
  local old, new = diff.word_diff('a = foo(b, c)', 'a = bar(b, d)')
  H.eq({ old, new }, { { { 4, 7 }, { 11, 12 } }, { { 4, 7 }, { 11, 12 } } })
end)
H.test('UTF-8 words stay whole', function()
  local old, new = diff.word_diff('x = "héllo"', 'x = "wörld"')
  H.eq({ old, new }, { { { 5, 11 } }, { { 5, 11 } } })
end)
H.test('dissimilar lines get no word highlight', function()
  H.eq({ diff.word_diff('foo(bar)', 'completely different') }, { {}, {} })
end)
H.test('a blank line on either side gets no word highlight', function()
  H.eq({ diff.word_diff('', 'x = 1') }, { {}, {} })
  H.eq({ diff.word_diff('x = 1', '') }, { {}, {} })
  H.eq({ diff.word_diff('', '') }, { {}, {} })
end)

H.section('hunk_of / stops / map_line')
H.test('hunk_of uses new lines on RIGHT and old lines on LEFT', function()
  H.eq({ diff.hunk_of(a, 5, 'RIGHT'), diff.hunk_of(a, 6, 'RIGHT'), diff.hunk_of(a, 5, 'LEFT'), diff.hunk_of(a, 6, 'LEFT') }, { 1, nil, 1, nil })
end)
H.test('stops are the first line of each change on that side', function()
  H.eq({ diff.stops(a, 'RIGHT'), diff.stops(a, 'LEFT') }, { { 2, 4, 5 }, { 2, 4, 6 } })
end)
H.test('map_line: a changed line maps to its paired line', function()
  H.eq({ diff.map_line(a, 2, 'new', 'old'), diff.map_line(a, 2, 'old', 'new') }, { 2, 2 })
end)
H.test('map_line: context lines map across', function()
  H.eq({ diff.map_line(a, 4, 'new', 'old'), diff.map_line(a, 5, 'old', 'new') }, { 5, 4 })
end)
H.test('map_line: unpaired lines map to the nearest line before them', function()
  H.eq({ diff.map_line(a, 5, 'new', 'old'), diff.map_line(a, 4, 'old', 'new') }, { 5, 3 })
end)
H.test('map_line: lines past a hunk shift by its size', function()
  H.eq({ diff.map_line(b, 10, 'new', 'old'), diff.map_line(b, 9, 'old', 'new'), diff.map_line(b, 1, 'new', 'old') }, { 9, 10, 1 })
end)

H.section('render')
local ns = vim.api.nvim_create_namespace('test')
local function marks(lines, file, side)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  diff.render(buf, file, side, ns)
  local got = { line_hl = {}, numbers = {}, signs = {}, virt = {}, words = {} }
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local row, col, x = m[2], m[3], m[4]
    if x.line_hl_group then table.insert(got.line_hl, { row, x.line_hl_group }) end
    if x.number_hl_group then table.insert(got.numbers, row) end
    if x.sign_text then table.insert(got.signs, { row, vim.trim(x.sign_text) }) end
    if x.hl_group then table.insert(got.words, { row, col, x.end_col, x.hl_group }) end
    if x.virt_lines then
      got.virt[row] = vim.tbl_map(function(vl)
        return (table.concat(vim.tbl_map(function(c) return c[1] end, vl)):gsub('%s+$', ''))
      end, x.virt_lines)
      got.virt[row].above = x.virt_lines_above
    end
  end
  return got
end

H.test('head: additions in place, deletions as virtual lines, word highlights', function()
  local m = marks({ 'local x = 1', 'return x + 2', 'end', 'keep', 'added' }, a, 'RIGHT')
  H.eq(m.line_hl, { { 1, 'CritiqueAdd' }, { 4, 'CritiqueAdd' } })
  H.eq(m.signs, { { 1, '+' }, { 4, '+' } })
  H.eq(m.words, { { 1, 11, 12, 'CritiqueAddWord' } })
  H.eq({ m.virt[1][1], m.virt[1].above, m.virt[3][1] }, { 'return x + 1', true, 'gone' })
end)
H.test('head: every hunk line number is tinted as commentable', function()
  H.eq(marks({ 'local x = 1', 'return x + 2', 'end', 'keep', 'added' }, a, 'RIGHT').numbers, { 0, 1, 2, 3, 4 })
end)
H.test('base: deletions in place, additions as virtual lines', function()
  local m = marks({ 'local x = 1', 'return x + 1', 'end', 'gone', 'keep' }, a, 'LEFT')
  H.eq(m.line_hl, { { 1, 'CritiqueDelete' }, { 3, 'CritiqueDelete' } })
  H.eq(m.signs, { { 1, '-' }, { 3, '-' } })
  H.eq({ m.virt[2][1], m.virt[4] and m.virt[4][1] }, { 'return x + 2', 'added' })
end)
H.test('additions after the last line attach below it', function()
  local m = marks({ 'local x = 1', 'return x + 1', 'end', 'gone', 'keep' }, a, 'LEFT')
  H.eq(m.virt[4].above, false)
end)
H.test('a fully deleted file shows its lines on an empty buffer', function()
  local m = marks({ '' }, d, 'RIGHT')
  H.eq({ m.virt[0][1], m.virt[0][2], m.virt[0].above }, { '-- x', 'b', true })
end)
H.test('tabs in virtual lines are expanded to the tabstop', function()
  local f = diff.parse('diff --git a/t b/t\n--- a/t\n+++ b/t\n@@ -1,2 +1,1 @@\n-\tx\n keep\n')[1]
  local m = marks({ 'keep' }, f, 'RIGHT')
  H.eq(m.virt[0][1], (' '):rep(vim.o.tabstop) .. 'x')
end)
H.test('marks past the end of a shorter buffer are clamped, not errors', function()
  marks({ 'only one line' }, a, 'RIGHT')
end)


H.section('parse: real-world git output (coverage review)')
H.test('a path with a space ends in a TAB on ---/+++ lines; the TAB is not part of the path', function()
  local f = diff.parse('diff --git a/my file.txt b/my file.txt\n--- a/my file.txt\t\n+++ b/my file.txt\t\n@@ -1 +1 @@\n-a\n+b\n')[1]
  H.eq({ f.path, f.old_path }, { 'my file.txt', 'my file.txt' })
end)

H.done()
