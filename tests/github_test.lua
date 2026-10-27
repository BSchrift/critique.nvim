-- Integration tests for GitHub PRs in the Neovim UI, offline: GitHub's API is stubbed, and the PR's repo is a
-- local one, cloned where critique keeps its PR checkouts. Run: nvim --headless -l tests/github_test.lua
local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
H.forbid_gh()
vim.env.XDG_CACHE_HOME = H.tmp .. '/cache'
vim.opt.rtp:prepend(H.plugin)
vim.cmd.runtime('plugin/critique.lua')
vim.o.swapfile = false
local gh = require('critique.gh')

local messages = {}
vim.notify = function(msg, level) table.insert(messages, { msg = msg, level = level }) end
local function messages_since(n) return vim.tbl_map(function(m) return m.msg end, vim.list_slice(messages, n + 1)) end

-- The PR: main is its base, and the pr branch its head.
local origin = H.repo({ ['a.txt'] = { 'one', 'two', 'three' }, ['b.txt'] = { 'bee' } })
H.git(origin, 'checkout', '-q', '-b', 'pr')
H.write(origin, 'a.txt', { 'one', 'TWO', 'three' })
H.git(origin, 'commit', '-qam', 'first')
local URL = 'https://github.example/o/r/pull/7'
-- critique clones https://github.example/o/r.git once; a clone of the local repo stands in for it.
local cache = vim.fn.stdpath('cache') .. '/critique/github.example/o/r'
vim.fn.mkdir(cache, 'p')
H.git(cache, 'clone', '-q', '--bare', origin, cache .. '/repo.git')
local checkout = cache .. '/pr-7'

gh.gql = function(_, query)
  assert(query:find('reviewThreads'), 'only the PR query is expected')
  return { repository = { pullRequest = {
    id = 'PR_7', title = 'Change two', headRefOid = H.git(origin, 'rev-parse', 'pr'), baseRefOid = H.git(origin, 'rev-parse', 'main'),
    reviews = { nodes = {} }, submitted = { nodes = {} }, files = { nodes = {} }, reviewThreads = { nodes = {} },
  } } }
end

local function open()
  local before = #messages
  vim.cmd('silent! %bwipeout!')
  vim.cmd('Critique open ' .. URL)
  H.wait_for(function()
    return vim.iter(messages_since(before)):any(function(m) return m:find(' changed', 1, true) or m:find('error', 1, true) end)
  end, 'the PR to open')
  return messages_since(before)
end

H.section('opening a PR')
H.test('checks out the head and lists the changed files', function()
  local msgs = open()
  H.has(msgs[#msgs], '#7 Change two · 1 file changed')
  H.eq(vim.fn.readfile(checkout .. '/a.txt'), { 'one', 'TWO', 'three' })
end)
H.test('reopening keeps edits in the checkout when the new commits leave them alone', function()
  H.write(checkout, 'b.txt', { 'mine' })
  open()
  H.eq({ vim.fn.readfile(checkout .. '/b.txt'), H.git(checkout, 'stash', 'list') }, { { 'mine' }, '' })
  H.git(checkout, 'checkout', 'b.txt')
end)
H.test('reopening after new commits stashes edits in their way, instead of failing', function()
  H.write(checkout, 'a.txt', { 'one', 'mine', 'three' })
  H.write(origin, 'a.txt', { 'one', 'TWO!', 'three' })
  H.git(origin, 'commit', '-qam', 'second')
  local msgs = open()
  H.eq(vim.fn.readfile(checkout .. '/a.txt'), { 'one', 'TWO!', 'three' }, 'the checkout is at the new head')
  H.has(msgs[#msgs], "your edits to a.txt in the PR's checkout were in the way of its new commits, so they're stashed")
  H.has(msgs[#msgs], 'stash pop')
  H.has(H.git(checkout, 'stash', 'list'), 'critique: your edits, set aside to reopen PR #7')
  H.has(H.git(checkout, 'stash', 'show', '-p'), '+mine')
end)

H.done()
