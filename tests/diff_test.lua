-- Run from the repo root: nvim --headless -l tests/diff_test.lua
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
local diff = require('critique.diff')
local eq = function(a, b, what) assert(vim.deep_equal(a, b), ('%s: expected %s, got %s'):format(what, vim.inspect(b), vim.inspect(a))) end

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
]])

local a, b, r, d = unpack(files)
eq(#files, 4, 'file count')
eq({ a.path, a.status, a.adds, a.dels }, { 'a.lua', 'M', 2, 2 }, 'a.lua')
eq(vim.tbl_map(function(blk) return { blk.new, blk.old, blk.old_end, #blk.dels, #blk.adds } end, a.blocks),
  { { 2, 2, 3, 1, 1 }, { 4, 4, 5, 1, 0 }, { 5, 6, 6, 0, 1 } }, 'a.lua blocks')
eq(a.anchor_left, { 1, 2, 3, 4, 4 }, 'deleted line 4 shows above new line 4')
eq(a.blocks[1].adds[1].words, { { 11, 12 } }, 'word diff on the paired line')
eq({ diff.hunk_of(a, 5, 'RIGHT'), diff.hunk_of(a, 6, 'RIGHT'), diff.hunk_of(a, 5, 'LEFT') }, { 1, nil, 1 }, 'hunk_of')
eq({ diff.map_line(a, 2, 'new', 'old'), diff.map_line(a, 4, 'new', 'old'), diff.map_line(a, 5, 'new', 'old') }, { 2, 5, 5 }, 'map new->old')
eq({ diff.map_line(b, 10, 'new', 'old'), diff.map_line(b, 9, 'old', 'new'), diff.map_line(b, 1, 'new', 'old') }, { 9, 10, 1 }, 'map past a hunk')
eq({ r.path, r.old_path, r.status, r.hunks[1].old_count }, { 'new name.txt', 'old name.txt', 'R', 1 }, 'rename')
eq({ d.path, d.status, d.blocks[1].dels[1].text, d.blocks[1].new }, { 'gone.txt', 'D', '-- x', 0 }, 'deleted file')
eq({ diff.word_diff('foo(bar)', 'completely different') }, { {}, {} }, 'dissimilar lines get no word highlight')
eq({ diff.word_diff('', 'x = 1') }, { {}, {} }, 'blank line replaced by text')
eq({ diff.word_diff('x = 1', '') }, { {}, {} }, 'text replaced by blank line')

-- Render the head side of a.lua and check what lands where.
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'local x = 1', 'return x + 2', 'end', 'keep', 'added' })
local ns = vim.api.nvim_create_namespace('test')
diff.render(buf, a, 'RIGHT', ns)
local lines_hl, virt, numbers = {}, {}, {}
for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
  if m[4].line_hl_group then lines_hl[#lines_hl + 1] = m[2] end
  if m[4].number_hl_group then numbers[#numbers + 1] = m[2] end
  if m[4].virt_lines then virt[m[2]] = m[4].virt_lines[1][1][1] .. (m[4].virt_lines[1][2] or { '' })[1] end
end
eq(lines_hl, { 1, 4 }, 'added rows highlighted')
eq(numbers, { 0, 1, 2, 3, 4 }, 'every row of the hunk is marked commentable')
eq({ virt[1], virt[3] }, { 'return x + 1', 'gone' .. (' '):rep(500) }, 'deleted lines as virtual lines')

print('ok')
