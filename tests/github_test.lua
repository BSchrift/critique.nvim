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
-- "GitHub's" PR threads, files' viewed states, overview, and the commit of your last review
local threads, files, overview, reviewed = {}, {}, nil, nil
local pages = 0 -- PR queries answered
-- A GitHub list, 100 a page: the page after cursor `after`. Past the end, it's empty and has no cursor.
local function page(nodes, after)
  local from = tonumber(after) or 0
  local last = math.min(#nodes, from + 100)
  return { nodes = vim.list_slice(nodes, from + 1, last), pageInfo = { hasNextPage = last < #nodes, endCursor = last > from and tostring(last) or nil } }
end
gh.gql = function(_, query, vars)
  if query:find('statusCheckRollup') then return { repository = { pullRequest = overview } } end
  assert(query:find('reviewThreads'), 'unexpected query')
  pages = pages + 1
  local repo = origins[vars.name]
  return { repository = { pullRequest = {
    id = 'PR_' .. vars.number, title = 'Change two', headRefOid = H.git(repo, 'rev-parse', 'pr'), baseRefOid = H.git(repo, 'rev-parse', 'main'),
    reviews = { nodes = {} }, files = page(files, vars.files), reviewThreads = page(vim.deepcopy(threads), vars.reviewThreads),
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
H.test('a new file of yours in the way of new commits is stashed too', function()
  H.write(checkout, 'c.txt', { 'mine' })
  H.write(origin, 'c.txt', { 'theirs' })
  H.git(origin, 'add', 'c.txt')
  push(origin, 7, { 'one', 'TWO!', 'three' })
  local msgs = open()
  H.eq(vim.fn.readfile(checkout .. '/c.txt'), { 'theirs' })
  H.has(msgs[#msgs], "your edits to c.txt in the PR's checkout were in the way of its new commits, so they're stashed")
  H.eq(H.git(checkout, 'show', 'stash@{0}^3:c.txt'), 'mine', 'in the stash, with the other new files')
end)
H.test('if the checkout still fails, the error says where your stashed edits went', function()
  H.write(checkout, 'a.txt', { 'mine again' })
  H.write(checkout, 'd/x.log', { 'ignored' }) -- git won't stash an ignored file, nor delete its folder
  local exclude = cache .. '/repo.git/info/exclude'
  H.write(cache .. '/repo.git', 'info/exclude', { '*.log' })
  H.write(origin, 'd', { 'a file where your folder is' })
  H.git(origin, 'add', 'd')
  push(origin, 7, { 'one', 'TWO!!', 'three' })
  local msgs = open()
  H.has(msgs[#msgs], 'would lose untracked files')
  H.has(msgs[#msgs], "your edits to a.txt in the PR's checkout were in the way of its new commits, so they're stashed")
  vim.fn.delete(checkout .. '/d', 'rf')
  vim.fn.delete(exclude)
  H.has(open()[1], '#7 Change two')
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
H.test("the files' ids go to git in one piece, not one write per file", function()
  local system, stdin = vim.system, nil
  vim.system = function(cmd, opts, ...)
    if vim.tbl_contains(cmd, '--stdin') then stdin = opts.stdin end
    return system(cmd, opts, ...)
  end
  local ok, err = pcall(open, nil, URL8)
  vim.system = system
  assert(ok, err)
  H.eq(type(stdin), 'string')
  local ids = {}
  for id in H.git(origin8, 'ls-tree', '-r', 'pr'):gmatch(' blob (%x+)\t') do ids[#ids + 1] = id end
  H.eq(stdin, table.concat(ids, '\n') .. '\n')
end)
H.test('reopening a PR whose checkout folder you deleted makes a new one', function()
  vim.cmd('silent! %bwipeout!')
  vim.fn.delete(cache8 .. '/pr-8', 'rf')
  local msgs = open(nil, URL8)
  H.has(msgs[#msgs], '#8 Change two · 1 file changed')
  H.eq(vim.fn.readfile(cache8 .. '/pr-8/a.txt'), { 'one', 'TWO again', 'three' })
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

H.section('a comment belongs to its PR')
-- Opens a PR like open(), but from the window you were in before, keeping the comment you're writing.
local function open_beside(url)
  local cwin, before = vim.api.nvim_get_current_win(), #messages
  vim.cmd.wincmd('p')
  vim.cmd('Critique open ' .. (url or URL))
  H.wait_for(function()
    return vim.iter(messages_since(before)):any(function(m) return m:find(' changed', 1, true) end)
  end, 'the PR to open')
  vim.fn.win_gotoid(cwin)
end
local function type_comment(text)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  vim.api.nvim_buf_set_lines(0, #lines - 1, -1, false, { text })
end
local function refused_write()
  local count, before = #sent, #messages
  vim.cmd('write')
  H.wait_for(function() return #messages > before end, 'the refusal')
  H.eq({ #sent, vim.bo.modified }, { count, true }, 'sent nothing, and the text is still there')
  local msg = messages[#messages].msg
  vim.cmd('quit!')
  return msg
end
H.test('a comment started before reopening the same PR still saves', function()
  open()
  on_line('a.txt', 2)
  vim.cmd('Critique comment')
  open_beside()
  write_comment('Still for PR 7')
  H.eq(last_sent('addPullRequestReviewThread').body, 'Still for PR 7' .. FOOTER)
end)
H.test('a comment started before opening another PR is refused, and kept', function()
  open()
  on_line('a.txt', 2)
  vim.cmd('Critique comment')
  type_comment('For PR 7')
  open_beside(URL8)
  H.has(refused_write(), 'this comment is for #7 Change two, which is no longer open')
end)
H.test('a new comment started before the PR got new commits is refused, since its line may have moved', function()
  open()
  on_line('a.txt', 2)
  vim.cmd('Critique comment')
  type_comment('On the old line 2')
  push(origin, 7, { 'zero', 'one', 'TWO!!', 'three' })
  open_beside()
  H.has(refused_write(), 'the PR has new commits since you started this comment')
end)

H.section('suggestions')
local function float_open()
  return vim.iter(vim.api.nvim_list_wins()):any(function(w) return vim.api.nvim_win_get_config(w).relative ~= '' end)
end
H.test('y posts before you can type again: the file is back as it was, and a second :w has nothing to post', function()
  open()
  on_line('a.txt', 3)
  local disk = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  vim.api.nvim_buf_set_lines(0, 2, 3, false, { 'TWO?' })
  local count = #sent
  vim.cmd('write')
  H.wait_for(float_open, 'the suggestion window')
  vim.api.nvim_feedkeys('y', 'x', false)
  H.eq({ vim.api.nvim_buf_get_lines(0, 0, -1, false), vim.bo.modified }, { disk, false }, 'posted and put back already')
  local before = #messages
  vim.cmd('write')
  H.wait_for(function() return #messages > before end, 'the second :w')
  H.has(messages[#messages].msg, 'no edits to suggest in a.txt')
  H.eq(vim.tbl_map(function(m) return m[1] end, vim.list_slice(sent, count + 1)), { 'addPullRequestReview', 'addPullRequestReviewThread' })
end)

H.section('big PRs')
H.test('every thread and viewed mark arrives, past the first 100', function()
  local many = {}
  for i = 1, 250 do
    many[i] = { id = 'T_' .. i, isResolved = false, isOutdated = false, path = 'a.txt', line = 3, diffSide = 'RIGHT', comments = { nodes = {
      { id = 'C_' .. i, databaseId = i, body = 'Thread ' .. i, state = 'SUBMITTED', viewerDidAuthor = false, author = { login = 'amy' } },
    } } }
  end
  for i = 1, 149 do files[i] = { path = ('other%d.txt'):format(i), viewerViewedState = 'UNVIEWED' } end
  files[150] = { path = 'a.txt', viewerViewedState = 'VIEWED' }
  pages = 0
  local ok, err = pcall(function()
    open(many)
    H.eq(pages, 3, '250 threads are 3 pages')
    local a = vim.iter(vim.fn.getqflist()):find(function(i) return vim.fn.bufname(i.bufnr):find('a%.txt$') end)
    H.has(a.text, '✓ ', 'a.txt, the 150th file, is viewed')
    vim.cmd('Critique threads')
    H.wait_for(function() return vim.fn.getqflist({ title = 0 }).title:find('open threads') end, 'the thread list')
    local seen = {}
    for _, item in ipairs(vim.fn.getqflist()) do seen[tonumber(item.text:match('Thread (%d+)'))] = true end
    H.eq({ vim.tbl_count(seen), seen[250] }, { 250, true }, 'each thread once, the newest too')
  end)
  files = {}
  assert(ok, err)
end)

H.section('links, threads, viewed marks, and the overview')
local function where() return (vim.api.nvim_buf_get_name(0):gsub('^.*/pr%-7/', '')) .. ':' .. vim.fn.line('.') end
local function mine(id, resolved) -- a thread on a.txt:3 with your pending comment
  return { id = 'T_' .. id, isResolved = resolved or false, isOutdated = false, path = 'a.txt', line = 3, diffSide = 'RIGHT', comments = { nodes = {
    { id = 'C_' .. id, databaseId = id, body = 'Mine', state = 'PENDING', viewerDidAuthor = true, author = { login = 'me' } },
  } } }
end
-- Runs a :Critique command and returns the message it ends with.
local function run(cmd)
  local before = #messages
  vim.cmd(cmd)
  H.wait_for(function() return #messages > before end, cmd)
  return messages[#messages].msg
end
H.test('a link to a line, a file, or a comment opens there', function()
  local hash = vim.fn.sha256('a.txt')
  open(nil, URL .. '/files#diff-' .. hash .. 'R3')
  H.eq(where(), 'a.txt:3')
  open(nil, URL .. '/files#diff-' .. hash .. 'L2')
  H.eq(where(), 'critique://base/a.txt:2')
  open(nil, URL .. '/files#diff-' .. hash)
  H.eq(where(), 'a.txt:1', "the file's first change")
  open({ mine(42) }, URL .. '#discussion_r42')
  H.eq(where(), 'a.txt:3')
  local msgs = open(nil, URL .. '/files#diff-' .. vim.fn.sha256('nope.txt'))
  H.ok(vim.iter(msgs):any(function(m) return m:find("the link points at something that is not in this PR's diff", 1, true) end), vim.inspect(msgs))
end)
H.test(':Critique link copies a permalink to the line or lines, at the commit the buffer shows', function()
  open()
  on_line('a.txt', 3)
  local head, base = H.git(origin, 'rev-parse', 'pr'), H.git(origin, 'merge-base', 'main', 'pr')
  vim.cmd('Critique link')
  H.eq(vim.fn.getreg('"'), ('https://github.example/o/r/blob/%s/a.txt#L3'):format(head))
  vim.cmd('2,3Critique link')
  H.eq(vim.fn.getreg('"'), ('https://github.example/o/r/blob/%s/a.txt#L2-L3'):format(head))
  vim.cmd('Critique before')
  vim.cmd('Critique link')
  H.eq(vim.fn.getreg('"'), ('https://github.example/o/r/blob/%s/a.txt#L2'):format(base), 'the base version, at the line mapped there')
end)
H.test('resolve, unresolve, delete, and viewed go to GitHub', function()
  local select = vim.ui.select
  vim.ui.select = function(items, _, cb) cb(items[1]) end
  local ok, err = pcall(function()
    open({ mine(5) })
    on_line('a.txt', 3)
    H.eq(run('Critique resolve'), 'critique: thread resolved')
    H.eq(last_sent('resolveReviewThread'), { threadId = 'T_5' })
    H.eq(run('Critique delete'), 'critique: comment deleted')
    H.eq(last_sent('deletePullRequestReviewComment'), { id = 'C_5' })
    open({ mine(6, true) })
    on_line('a.txt', 3)
    H.eq(run('Critique resolve'), 'critique: thread unresolved')
    H.eq(last_sent('unresolveReviewThread'), { threadId = 'T_6' })
    H.has(run('Critique viewed'), 'viewed')
    H.eq(last_sent('markFileAsViewed'), { pullRequestId = 'PR_7', path = 'a.txt' })
    H.ok(where() ~= 'a.txt:3', 'moved on to the next file')
    on_line('a.txt', 3)
    H.has(run('Critique viewed'), 'not viewed: a.txt')
    H.eq(last_sent('unmarkFileAsViewed'), { pullRequestId = 'PR_7', path = 'a.txt' })
  end)
  vim.ui.select = select
  assert(ok, err)
end)
H.test('the overview counts the checks that passed and lists the rest', function()
  overview = { url = URL, body = '', state = 'OPEN', isDraft = true, reviewDecision = 'CHANGES_REQUESTED', baseRefName = 'main',
    headRefName = 'pr', author = { login = 'amy' }, comments = { nodes = {} }, reviews = { nodes = {} },
    commits = { nodes = { { commit = { statusCheckRollup = { state = 'FAILURE', contexts = { nodes = {
      { name = 'lint', status = 'COMPLETED', conclusion = 'SUCCESS' },
      { name = 'docs', status = 'COMPLETED', conclusion = 'SKIPPED' },
      { name = 'test (linux)', status = 'COMPLETED', conclusion = 'FAILURE' },
      { name = 'deploy', status = 'IN_PROGRESS' },
      { context = 'ci/legacy', state = 'SUCCESS' },
    } } } } } } } }
  open()
  vim.cmd('Critique overview')
  H.wait_for(function() return vim.api.nvim_buf_get_name(0) == 'critique://overview' end, 'the overview')
  H.eq(vim.api.nvim_buf_get_lines(0, 1, 9, false), {
    'amy wants to merge `pr` into `main` · open · draft', URL, '',
    'Review: changes requested',
    'Checks: failure · 2 passed, 1 skipped',
    '- ✗ test (linux) (failure)',
    '- • deploy (in progress)',
    '',
  })
  vim.cmd('quit')
end)

H.done()
