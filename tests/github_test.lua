-- Integration tests for GitHub PRs in the Neovim UI, offline: GitHub's API is stubbed, and the PRs' repos are
-- local ones. Run: nvim --headless -l tests/github_test.lua
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
local echoes = {} -- the progress line while a PR opens
vim.api.nvim_echo = function(chunks) table.insert(echoes, chunks[1][1]) end

-- A PR's repo: main is its base, and the pr branch its head, which GitHub also has as refs/pull/<n>/head.
local origins = {}
local function pr_repo(name, n)
  local repo = H.repo({ ['a.txt'] = { 'one', 'two', 'three' }, ['b.txt'] = { 'bee' } })
  for i = 1, 3 do -- some history, which opening a PR shouldn't download
    H.write(repo, 'history.txt', { tostring(i) })
    H.git(repo, 'add', '-A')
    H.git(repo, 'commit', '-qm', 'history ' .. i)
  end
  H.git(repo, 'checkout', '-q', '-b', 'pr')
  H.write(repo, 'a.txt', { 'one', 'TWO', 'three' })
  H.git(repo, 'commit', '-qam', 'first')
  H.git(repo, 'update-ref', ('refs/pull/%d/head'):format(n), 'pr')
  -- Let fetches ask for commits by id and leave out file contents, as GitHub does.
  H.git(repo, 'config', 'uploadpack.allowfilter', 'true')
  H.git(repo, 'config', 'uploadpack.allowanysha1inwant', 'true')
  origins[name] = repo
  return repo
end
-- A new commit on the PR's head.
local function push(repo, n, lines)
  H.write(repo, 'a.txt', lines)
  H.git(repo, 'commit', '-qam', 'more')
  H.git(repo, 'update-ref', ('refs/pull/%d/head'):format(n), 'pr')
end

-- PR 7 is in a full clone, as critique made them before 0.4.
local origin = pr_repo('r', 7)
local URL = 'https://github.example/o/r/pull/7'
local cache = vim.fn.stdpath('cache') .. '/critique/github.example/o/r'
vim.fn.mkdir(cache, 'p')
H.git(cache, 'clone', '-q', '--bare', origin, cache .. '/repo.git')
local checkout = cache .. '/pr-7'
-- PR 8 has no cache yet: critique downloads it from "GitHub", which is the local repo.
local origin8 = pr_repo('s', 8)
H.git(H.tmp, 'config', '--global', 'url.file://' .. origin8 .. '.insteadOf', 'https://github.example/o/s.git')
gh.merge_base = function(_, _, name, base, head) return H.git(origins[name], 'merge-base', base, head) end

local FOOTER = '\n\n<sub>Made with <a href="https://github.com/BSchrift/critique.nvim"><img src="'
  .. 'https://raw.githubusercontent.com/BSchrift/critique.nvim/main/assets/icon-512.png" height="14" align="texttop" '
  .. 'alt="c">ritique.nvim</a></sub>'
local OLD_FOOTERS = { -- earlier versions' footers, which critique hides too
  '\n\n<sub>Made with [critique.nvim](https://github.com/BSchrift/critique.nvim)</sub>',
  '\n\n<sub><a href="https://github.com/BSchrift/critique.nvim"><img src="https://raw.githubusercontent.com/BSchrift/critique.nvim/main/assets/icon-512.png" height="14" alt=""></a> Made with [critique.nvim](https://github.com/BSchrift/critique.nvim)</sub>',
}
local threads, overview, reviewed = {}, nil, nil -- "GitHub's" PR threads, overview, and the commit of your last review
gh.gql = function(_, query, vars)
  if query:find('statusCheckRollup') then return { repository = { pullRequest = overview } } end
  assert(query:find('reviewThreads'), 'unexpected query')
  local repo = origins[vars.name]
  return { repository = { pullRequest = {
    id = 'PR_' .. vars.number, title = 'Change two', headRefOid = H.git(repo, 'rev-parse', 'pr'), baseRefOid = H.git(repo, 'rev-parse', 'main'),
    reviews = { nodes = {} }, files = { nodes = {} }, reviewThreads = { nodes = vim.deepcopy(threads) },
    submitted = { nodes = reviewed and { { viewerDidAuthor = true, commit = { oid = reviewed } } } or {} },
  } } }
end
local sent, offline = {}, false -- the mutations critique sends: { name, input }; offline makes them fail
gh.mutate = function(_, name, input)
  table.insert(sent, { name, input })
  gh.await(function(cb) vim.defer_fn(cb, 30) end) -- GitHub takes a moment to answer
  if offline then error('error connecting to api.github.example', 0) end
  return ({
    addPullRequestReview = { pullRequestReview = { id = 'R_1' } },
    addPullRequestReviewThread = { thread = { id = 'T_1', comments = { nodes = { { id = 'C_1' } } } } },
    addPullRequestReviewThreadReply = { comment = { id = 'C_2' } },
  })[name] or {}
end
local function last_sent(name)
  for i = #sent, 1, -1 do
    if sent[i][1] == name then return sent[i][2] end
  end
end

-- Opens the PR (PR 7 unless given), with `with_threads` as its review threads on "GitHub".
local function open(with_threads, url)
  threads = with_threads or {}
  local before = #messages
  vim.cmd('silent! %bwipeout!')
  vim.cmd('Critique open ' .. (url or URL))
  H.wait_for(function()
    return vim.iter(messages_since(before)):any(function(m) return m:find(' changed', 1, true) or m:find('error', 1, true) end)
  end, 'the PR to open')
  return messages_since(before)
end

H.section(':Critique with no subcommand')
H.test('with no review open, it opens the help', function()
  vim.cmd.helptags(H.plugin .. '/doc') -- plugin managers do this on install
  vim.cmd('Critique')
  H.eq({ vim.bo.filetype, vim.fn.expand('%:t') }, { 'help', 'critique.txt' })
  vim.cmd('helpclose')
end)

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
  push(origin, 7, { 'one', 'TWO!', 'three' })
  local msgs = open()
  H.eq(vim.fn.readfile(checkout .. '/a.txt'), { 'one', 'TWO!', 'three' }, 'the checkout is at the new head')
  H.has(msgs[#msgs], "your edits to a.txt in the PR's checkout were in the way of its new commits, so they're stashed")
  H.has(msgs[#msgs], 'stash pop')
  H.has(H.git(checkout, 'stash', 'list'), 'critique: your edits, set aside to reopen PR #7')
  H.has(H.git(checkout, 'stash', 'show', '-p'), '+mine')
end)

H.test('in an open review, it comments on the cursor line, instead of opening another review', function()
  open()
  vim.cmd.edit(checkout .. '/a.txt')
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.cmd('Critique')
  H.has(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], 'PR #7 · a.txt:2')
  vim.cmd('quit!')
  H.eq(vim.fn.isdirectory(checkout .. '/.critique'), 0, 'no local review started in the checkout')
end)
H.test(":Critique open with no argument refuses in critique's checkout of a PR", function()
  open()
  local before = #messages
  vim.cmd('Critique open')
  H.wait_for(function() return #messages > before end, 'the error')
  H.has(messages[#messages].msg, "this folder is critique's checkout of a GitHub PR")
  H.eq(vim.fn.isdirectory(checkout .. '/.critique'), 0)
end)

H.section('downloading a PR')
local URL8, cache8 = 'https://github.example/o/s/pull/8', vim.fn.stdpath('cache') .. '/critique/github.example/o/s'
H.test('the first open downloads just the commits the review needs, with a progress line', function()
  echoes = {}
  local msgs = open(nil, URL8)
  H.has(msgs[#msgs], '#8 Change two · 1 file changed')
  H.eq(vim.fn.readfile(cache8 .. '/pr-8/a.txt'), { 'one', 'TWO', 'three' })
  H.eq(H.git(cache8 .. '/repo.git', 'rev-list', '--count', H.git(origin8, 'rev-parse', 'pr')), '1', 'no history')
  H.eq(H.git(cache8 .. '/repo.git', 'rev-list', '--count', H.git(origin8, 'merge-base', 'main', 'pr')), '1', 'none for the merge base either')
  H.eq(vim.fn.systemlist({ 'git', '-C', cache8 .. '/repo.git', 'config', '--get-all', 'credential.helper' }), { '', '!gh auth git-credential' },
    "gh's credentials, and no others")
  H.eq(vim.fn.isdirectory(cache8 .. '/repo.git.new'), 0)
  H.ok(vim.iter(echoes):any(function(e) return e:find('critique: opening o/s#8', 1, true) end), vim.inspect(echoes))
  H.ok(not vim.iter(echoes):any(function(e) return e:find('FETCH_HEAD', 1, true) end), "only git's progress lines, not its other output")
  local count = #echoes
  vim.wait(300)
  H.eq(#echoes, count, 'the progress line stops once the PR is open')
end)
H.test('reopening after new commits downloads just the new head', function()
  push(origin8, 8, { 'one', 'TWO again', 'three' })
  open(nil, URL8)
  H.eq(vim.fn.readfile(cache8 .. '/pr-8/a.txt'), { 'one', 'TWO again', 'three' })
  H.eq(H.git(cache8 .. '/repo.git', 'rev-list', '--count', H.git(origin8, 'rev-parse', 'pr')), '1', 'still no history')
end)
H.test(':Critique since downloads the commit of your last review the same way', function()
  reviewed = H.git(origin8, 'rev-parse', 'pr~1')
  local ok, err = pcall(function()
    open(nil, URL8)
    local before = #messages
    vim.cmd('Critique since')
    H.wait_for(function() return #messages > before end, 'since')
    H.has(messages[#messages].msg, '1 file changed since your last review')
  end)
  reviewed = nil
  assert(ok, err)
end)
H.test('a failed download stops the progress line and says why', function()
  echoes = {}
  local before = #messages
  vim.cmd('Critique open https://github.example/o/s/pull/9') -- no such PR ref
  H.wait_for(function() return vim.iter(messages_since(before)):any(function(m) return m:find('refs/pull/9', 1, true) end) end, 'the error')
  local count = #echoes
  vim.wait(300)
  H.eq(#echoes, count, 'the progress line stopped')
end)

H.section('the critique.nvim footer')
local function below_mark()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local at = vim.iter(ipairs(lines)):find(function(_, l) return l:find('▼ write below', 1, true) end)
  return vim.list_slice(lines, at + 1)
end
local function write_comment(text)
  local before = #messages
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local at = vim.iter(ipairs(lines)):find(function(_, l) return l:find('▼ write below', 1, true) end)
  vim.api.nvim_buf_set_lines(0, at, -1, false, { text })
  vim.cmd('write')
  H.wait_for(function() return #messages > before end, 'the save')
  vim.cmd('quit')
end
local function on_line(path, n)
  vim.cmd.edit(checkout .. '/' .. path)
  vim.api.nvim_win_set_cursor(0, { n, 0 })
end

H.test('a new comment ends with the footer', function()
  open()
  on_line('a.txt', 2)
  vim.cmd('Critique comment')
  write_comment('Why the bang?')
  H.eq(last_sent('addPullRequestReviewThread').body, 'Why the bang?' .. FOOTER)
end)
H.test("earlier versions' footers are hidden too", function()
  for _, old in ipairs(OLD_FOOTERS) do
    open({ { id = 'T_2', isResolved = false, isOutdated = false, path = 'a.txt', line = 2, diffSide = 'RIGHT', comments = { nodes = {
      { id = 'C_9', databaseId = 9, body = 'Older\n\nsecond paragraph' .. old, state = 'SUBMITTED', viewerDidAuthor = false, author = { login = 'amy' } },
    } } } })
    on_line('a.txt', 2)
    vim.cmd('Critique comment')
    H.eq(vim.list_slice(vim.api.nvim_buf_get_lines(0, 0, -1, false), 4, 6), { 'Older', '', 'second paragraph' })
    vim.cmd('quit!')
  end
end)
H.test("editing your comment shows it without the footer and saves it with exactly one", function()
  open({ { id = 'T_1', isResolved = false, isOutdated = false, path = 'a.txt', line = 2, diffSide = 'RIGHT', comments = { nodes = {
    { id = 'C_1', databaseId = 1, body = 'Old text' .. FOOTER, state = 'PENDING', viewerDidAuthor = true, author = { login = 'me' } },
  } } } })
  on_line('a.txt', 2)
  local marks = vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace('critique.threads'), 0, -1, { details = true })
  H.eq(marks[1][4].virt_text[1][1], ' 💬 (1) · me: Old text')
  vim.cmd('Critique comment')
  H.eq(below_mark(), { 'Old text' })
  write_comment('New text')
  H.eq(last_sent('updatePullRequestReviewComment').body, 'New text' .. FOOTER)
end)
H.test('suggestions and review summaries end with it too; an empty summary stays empty', function()
  open()
  on_line('a.txt', 2)
  vim.api.nvim_buf_set_lines(0, 1, 2, false, { 'TWO' })
  vim.cmd('write')
  H.wait_for(function()
    return vim.iter(vim.api.nvim_list_wins()):any(function(w) return vim.api.nvim_win_get_config(w).relative ~= '' end)
  end, 'the suggestion window')
  vim.api.nvim_feedkeys('y', 'x', false)
  H.wait_for(function() return messages[#messages].msg:find('suggestion saved', 1, true) end, 'the suggestion')
  H.eq(last_sent('addPullRequestReviewThread').body, '```suggestion\nTWO\n```' .. FOOTER)
  local select, input = vim.ui.select, vim.ui.input
  for _, summary in ipairs({ 'Looks good', '' }) do
    vim.ui.select = function(items, _, cb) cb(items[1]) end
    vim.ui.input = function(_, cb) cb(summary) end
    local before = #messages
    vim.cmd('Critique submit')
    H.wait_for(function() return #messages > before end, 'the submit')
  end
  vim.ui.select, vim.ui.input = select, input
  local submits = vim.tbl_filter(function(m) return m[2].event ~= nil end, sent) -- submitting a pending review, or a new one
  H.eq({ submits[#submits - 1][2].body, submits[#submits][2].body }, { 'Looks good' .. FOOTER, nil })
end)
H.test(':wq saves the comment and closes it; if the save fails, the comment stays open', function()
  open()
  on_line('a.txt', 2)
  vim.cmd('Critique comment')
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  vim.api.nvim_buf_set_lines(0, #lines - 1, -1, false, { 'Saved and closed' })
  vim.cmd('wq')
  H.eq({ last_sent('addPullRequestReviewThread').body, vim.api.nvim_buf_get_name(0):find('critique://comment', 1, true) },
    { 'Saved and closed' .. FOOTER, nil })
  vim.cmd('Critique comment')
  lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  vim.api.nvim_buf_set_lines(0, #lines - 1, -1, false, { 'Not sent' })
  offline = true
  pcall(vim.cmd, 'wq')
  offline = false
  H.ok(vim.api.nvim_buf_get_name(0):find('critique://comment', 1, true), 'still open')
  H.eq(vim.api.nvim_buf_get_lines(0, -2, -1, false), { 'Not sent' })
  H.has(messages[#messages].msg, 'error connecting')
  vim.cmd('quit!')
end)
H.test('footer = false leaves it off', function()
  require('critique').setup({ footer = false })
  local ok, err = pcall(function()
    open()
    on_line('a.txt', 2)
    vim.cmd('Critique comment')
    write_comment('Plain')
    H.eq(last_sent('addPullRequestReviewThread').body, 'Plain')
  end)
  require('critique').setup({ footer = true })
  assert(ok, err)
end)
H.test("the overview doesn't show footers", function()
  overview = { url = URL, body = 'Desc', state = 'OPEN', isDraft = false, baseRefName = 'main', headRefName = 'pr', author = { login = 'me' },
    commits = { nodes = {} }, comments = { nodes = { { author = { login = 'amy' }, body = 'Ship it' .. FOOTER, createdAt = '2026-10-27T10:00:00Z' } } },
    reviews = { nodes = { { author = { login = 'me' }, body = FOOTER, state = 'COMMENTED', submittedAt = '2026-10-27T11:00:00Z' } } } }
  open()
  vim.cmd('Critique overview')
  H.wait_for(function() return vim.api.nvim_buf_get_name(0) == 'critique://overview' end, 'the overview')
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
  H.has(text, '### amy · 2026-10-27\n\nShip it')
  H.lacks(text, 'critique.nvim')
  H.lacks(text, '### me', 'a review that was only a footer is a bare review')
  vim.cmd('quit')
end)

H.done()
