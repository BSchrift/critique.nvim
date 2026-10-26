local gh = require('critique.gh')
local diff = require('critique.diff')
local store = require('critique.store')

local M = {}
local ns_diff = vim.api.nvim_create_namespace('critique.diff')
local ns_threads = vim.api.nvim_create_namespace('critique.threads')
local MARK = { github = '<!-- ▼ write below · :w saves to your pending review · :q closes ▼ -->',
  ['local'] = '<!-- ▼ write below · :w saves a draft · :q closes ▼ -->' }
local S -- the open review

-- shortcut: first 100 threads and 100 comments per thread; paginate if PRs outgrow that.
local PR_QUERY = [[
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      id title headRefOid baseRefOid
      reviews(states: PENDING, first: 1) { nodes { id } }
      reviewThreads(first: 100) {
        nodes {
          id isResolved path line diffSide
          comments(first: 100) { nodes { id databaseId body state viewerDidAuthor author { login } } }
        }
      }
    }
  }
}]]

-- GitHub's diff colors (Primer), blended onto GitHub's own background.
local COLORS = {
  dark = {
    CritiqueAdd = { bg = '#12261e' }, CritiqueAddWord = { bg = '#1a4a29' }, CritiqueAddSign = { fg = '#3fb950' },
    CritiqueDelete = { bg = '#301b1e' }, CritiqueDeleteWord = { bg = '#6b2b2b' }, CritiqueDeleteSign = { fg = '#f85149' },
    CritiqueHunk = { fg = '#8197b8', bg = '#232d3f' }, -- line numbers you can comment on
  },
  light = {
    CritiqueAdd = { bg = '#e6ffec' }, CritiqueAddWord = { bg = '#abf2bc' }, CritiqueAddSign = { fg = '#1a7f37' },
    CritiqueDelete = { bg = '#ffebe9' }, CritiqueDeleteWord = { bg = '#ffcecb' }, CritiqueDeleteSign = { fg = '#cf222e' },
    CritiqueHunk = { fg = '#57728f', bg = '#e3ebf5' },
  },
}

local function set_highlights()
  for name, val in pairs(COLORS[vim.o.background]) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend('force', val, { default = true }))
  end
  vim.api.nvim_set_hl(0, 'CritiqueThread', { link = 'DiagnosticInfo', default = true })
  vim.api.nvim_set_hl(0, 'CritiquePending', { link = 'DiagnosticWarn', default = true })
  vim.api.nvim_set_hl(0, 'CritiqueResolved', { link = 'Comment', default = true })
end

local function notify(msg, level)
  vim.notify('critique: ' .. msg, level)
end

local function login(c)
  return c.author and c.author.login or 'ghost'
end

local function first_line(s)
  return s:match('^[^\r\n]*')
end

local function split(s)
  return vim.split((s:gsub('\r', '')), '\n')
end

-- Path of a buffer within the PR and which side it shows: worktree files are RIGHT, critique://base/ buffers LEFT.
local function buf_path(buf)
  if not S then return end
  local name = vim.api.nvim_buf_get_name(buf)
  local base = name:match('^critique://base/(.+)')
  if base then return base, 'LEFT' end
  local prefix = S.dir .. '/'
  if name:sub(1, #prefix) == prefix then return name:sub(#prefix + 1), 'RIGHT' end
end

-- Line where thread t shows in buf, or nil. LEFT threads also show in the head, next to their deleted lines.
local function thread_line(buf, t, path, side)
  if t.path ~= path or not t.line then return end -- outdated threads have no line
  local lnum = t.line
  if t.diffSide ~= side then
    local file = S.by_path[path]
    if side == 'RIGHT' then
      lnum = file and file.anchor_left[t.line]
    else -- a thread on a file that has since been deleted shows on its old version
      lnum = file and file.status == 'D' and t.line
    end
  end
  return lnum and math.min(lnum, vim.api.nvim_buf_line_count(buf))
end

local function render_threads(buf, path, side)
  for _, t in ipairs(S.threads) do
    local lnum = thread_line(buf, t, path, side)
    if lnum then
      local pending = vim.iter(t.comments):any(function(c) return c.state == 'PENDING' end)
      local c = t.comments[1]
      local count = t.n and ('#%d (%d)'):format(t.n, #t.comments) or tostring(#t.comments)
      local text = (' %s %s · %s%s: %s'):format(t.isResolved and '✓' or '💬', count, t.outdated and 'outdated · ' or '', login(c), first_line(c.body))
      vim.api.nvim_buf_set_extmark(buf, ns_threads, lnum - 1, 0, {
        virt_text = { { text, t.isResolved and 'CritiqueResolved' or pending and 'CritiquePending' or 'CritiqueThread' } },
      })
    end
  end
end

local function jump(dir)
  local path, side = buf_path(0)
  local cur, last = vim.fn.line('.'), vim.fn.line('$')
  local stops = diff.stops(S.by_path[path], side)
  for i = dir > 0 and 1 or #stops, dir > 0 and #stops or 1, dir do
    local l = math.max(1, math.min(stops[i], last))
    if (l - cur) * dir > 0 then return vim.api.nvim_win_set_cursor(0, { l, 0 }) end
  end
end

local function decorate(buf)
  local path, side = buf_path(buf)
  if not path then return end
  vim.api.nvim_buf_clear_namespace(buf, ns_diff, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, ns_threads, 0, -1)
  local file = S.by_path[path]
  if file and S.overlay then diff.render(buf, file, side, ns_diff) end
  render_threads(buf, path, side)
  if file then
    vim.keymap.set('n', ']c', function() jump(1) end, { buffer = buf, desc = 'Next PR change' })
    vim.keymap.set('n', '[c', function() jump(-1) end, { buffer = buf, desc = 'Previous PR change' })
  end
end

local function redraw()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then decorate(b) end
  end
end

-- Loads the base version of a file into a critique://base/<path> buffer.
local function read_base(buf)
  local path = vim.api.nvim_buf_get_name(buf):match('^critique://base/(.+)')
  local file = S.by_path[path]
  local r = vim.system({ 'git', '-C', S.git_dir, 'show', S.base .. ':' .. (file and file.old_path or path) }):wait()
  if r.code ~= 0 then notify(path .. ' does not exist in the base version', vim.log.levels.WARN) end
  local lines = vim.split(r.stdout or '', '\n')
  if lines[#lines] == '' then lines[#lines] = nil end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype, vim.bo[buf].modifiable, vim.bo[buf].modified = 'nofile', false, false
  vim.bo[buf].filetype = vim.filetype.match({ filename = path, buf = buf }) or ''
  decorate(buf)
end

local function fetch_pr(st)
  local pr = gh.gql(st.host, PR_QUERY, { owner = st.owner, name = st.name, number = st.number }).repository.pullRequest
  st.pr_id, st.review_id = pr.id, (pr.reviews.nodes[1] or {}).id
  st.threads = vim.tbl_map(function(t)
    t.comments = t.comments.nodes
    return t
  end, pr.reviewThreads.nodes)
  return pr
end

-- A local review (see store.lua), in the same shape as GitHub's threads so the UI is shared.
local function load_local(st)
  local r = store.load(st.log, 'human')
  st.review, st.base, st.title = r, r.base, r.id .. ' · ' .. r.title
  st.files, st.by_path = diff.parse(store.diff(r)), {}
  for _, f in ipairs(st.files) do st.by_path[f.path] = f end
  st.threads = vim.tbl_map(function(t)
    return { -- an outdated thread stays where its code was, so you can still read and answer it
      id = t.id, n = t.n, path = t.path, line = t.line or t.orig_line, outdated = t.outdated, isResolved = t.resolved,
      diffSide = t.side == 'old' and 'LEFT' or 'RIGHT',
      comments = vim.tbl_map(function(c)
        return { id = c.id, body = c.body, state = c.pending and 'PENDING' or 'SUBMITTED', viewerDidAuthor = c.role == 'human', author = { login = c.author } }
      end, t.comments),
    }
  end, r.threads)
end

local function set_qf()
  local items = vim.tbl_map(function(f)
    local side = f.status == 'D' and 'LEFT' or 'RIGHT'
    return {
      filename = side == 'LEFT' and 'critique://base/' .. f.path or S.dir .. '/' .. f.path,
      lnum = diff.stops(f, side)[1] or 1,
      text = ('%s  +%d -%d'):format(f.status, f.adds, f.dels),
    }
  end, S.files)
  -- Local reviews can have threads on files outside the diff; list those too.
  local extra = {}
  for _, t in ipairs(S.review and S.threads or {}) do
    if not S.by_path[t.path] then
      extra[t.path] = extra[t.path] or { filename = S.dir .. '/' .. t.path, lnum = t.line, count = 0 }
      extra[t.path].count = extra[t.path].count + 1
    end
  end
  for _, e in pairs(extra) do
    table.insert(items, { filename = e.filename, lnum = e.lnum, text = ('%d thread%s'):format(e.count, e.count == 1 and '' or 's') })
  end
  -- Replace our own list in place on refresh, so it never pushes your other quickfix lists off the stack.
  if not (S.qf_id and vim.fn.setqflist({}, 'r', { id = S.qf_id, title = S.title, items = items }) == 0) then
    vim.fn.setqflist({}, ' ', { title = S.title, items = items })
    S.qf_id = vim.fn.getqflist({ id = 0 }).id
  end
end

local function plural(n, word)
  return ('%d %s%s'):format(n, word, n == 1 and '' or 's')
end

local function refresh()
  if S.review then
    load_local(S) -- the agent may have changed files too
    set_qf()
    vim.cmd.checktime()
  else
    fetch_pr(S)
  end
  redraw()
end

local function writable()
  if S.review and S.review.closed then error('this review is closed', 0) end
end

local function ensure_review()
  S.review_id = S.review_id
    or gh.mutate(S.host, 'addPullRequestReview', { pullRequestId = S.pr_id, commitOID = S.head }, 'pullRequestReview { id }').pullRequestReview.id
  return S.review_id
end

local function save(buf, ctx)
  local lines, at = vim.api.nvim_buf_get_lines(buf, 0, -1, false), nil
  for i = #lines, 1, -1 do
    if lines[i]:find('^<!%-%- ▼ write below') then at = i break end
  end
  if not at then error('keep the "<!-- ▼ write below … ▼ -->" line; your comment goes below it', 0) end
  local body = vim.trim(table.concat(lines, '\n', at + 1))
  if body == '' then error('comment is empty; nothing saved', 0) end
  writable()
  if S.review then
    if ctx.comment then
      store.append(S.log, { type = 'edit', id = ctx.comment.id, body = body })
    else
      local ev = { type = 'comment', id = store.new_id(), author = S.me, role = 'human', body = body }
      ev.thread = ctx.thread and ctx.thread.id or ev.id
      if not ctx.thread then
        local a = ctx.anchor
        ev.path, ev.side, ev.line, ev.start_line, ev.code = a.path, a.side == 'LEFT' and 'old' or 'new', a.line, a.startLine, ctx.code
      end
      store.append(S.log, ev)
      ctx.comment = { id = ev.id }
    end
  elseif ctx.comment then
    gh.mutate(S.host, 'updatePullRequestReviewComment', { pullRequestReviewCommentId = ctx.comment.id, body = body })
  elseif ctx.thread then
    local input = { pullRequestReviewThreadId = ctx.thread.id, pullRequestReviewId = ensure_review(), body = body }
    ctx.comment = gh.mutate(S.host, 'addPullRequestReviewThreadReply', input, 'comment { id }').comment
  else
    local input = vim.tbl_extend('force', ctx.anchor, { pullRequestReviewId = ensure_review(), body = body })
    local t = gh.mutate(S.host, 'addPullRequestReviewThread', input, 'thread { id comments(first: 1) { nodes { id } } }').thread
    if not t then error('GitHub rejected the comment', 0) end
    ctx.comment = t.comments.nodes[1]
  end
  if vim.api.nvim_buf_is_valid(buf) then vim.bo[buf].modified = false end
  refresh()
  notify(S.review and 'saved; the agent sees it after :Critique submit' or 'saved to your pending review')
end

-- Opens a scratch markdown buffer: the thread so far, then your text below MARK. :w syncs to GitHub.
local function edit(ctx)
  local comments = ctx.thread and ctx.thread.comments or {}
  for _, c in ipairs(comments) do
    if c.viewerDidAuthor and c.state == 'PENDING' then ctx.comment = c end
  end
  local where = ctx.thread or ctx.anchor
  local status = ctx.thread and (ctx.thread.isResolved and ' · resolved' or ctx.thread.outdated and ' · outdated' or ' · open') or ''
  local lines = { ('<!-- %s%s · %s:%d%s -->'):format(S.number and 'PR #' .. S.number or S.review.id,
    ctx.thread and ctx.thread.n and (' #' .. ctx.thread.n) or '', where.path, where.line, status), '' }
  for _, c in ipairs(comments) do
    if c ~= ctx.comment then
      table.insert(lines, ('<!-- @%s%s -->'):format(login(c), c.state == 'PENDING' and ' (pending)' or ''))
      vim.list_extend(lines, split(c.body))
      table.insert(lines, '')
    end
  end
  table.insert(lines, MARK[S.review and 'local' or 'github'])
  vim.list_extend(lines, ctx.comment and split(ctx.comment.body) or { '' })

  vim.cmd('botright 12new')
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(buf, 'critique://comment/' .. buf)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile, vim.bo[buf].filetype = 'acwrite', 'wipe', false, 'markdown'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.api.nvim_win_set_cursor(0, { #lines, 0 })
  vim.api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = gh.async(function() save(buf, ctx) end) })
end

local function here()
  local path, side = buf_path(0)
  if not path then error('not a file in this review', 0) end
  return path, side
end

local function threads_here()
  local path, side = here()
  local lnum = vim.fn.line('.')
  return vim.tbl_filter(function(t) return thread_line(0, t, path, side) == lnum end, S.threads)
end

local function pick(items, prompt, fmt)
  if #items <= 1 then return items[1] end
  return gh.await(vim.ui.select, items, { prompt = prompt, format_item = fmt })
end

local function thread_label(t)
  return (t.n and ('#' .. t.n .. ' ') or '') .. login(t.comments[1]) .. ': ' .. first_line(t.comments[1].body)
end

local function swap(to)
  local path, side = here()
  if side == to then return end
  local file, lnum = S.by_path[path], vim.fn.line('.')
  if file then lnum = diff.map_line(file, lnum, side == 'RIGHT' and 'new' or 'old', to == 'RIGHT' and 'new' or 'old') end
  vim.cmd.edit(vim.fn.fnameescape(to == 'LEFT' and 'critique://base/' .. path or S.dir .. '/' .. path))
  pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
end

local function show(path, side, line)
  vim.cmd.edit(vim.fn.fnameescape(side == 'LEFT' and 'critique://base/' .. path or S.dir .. '/' .. path))
  pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
  vim.cmd('normal! zz')
end

-- Jump to what a pasted PR URL points at: #diff-<sha256 of path>[R|L<line>], or #discussion_r<comment id>.
local function goto_anchor(url)
  local hash, side, line = url:match('#diff%-(%x+)([LR]?)(%d*)')
  local id = tonumber(url:match('#discussion_r(%d+)'))
  if not hash and not id then return end
  local path
  if hash then
    for p in pairs(S.by_path) do
      if vim.fn.sha256(p) == hash then path = p end
    end
    side = side == 'L' and 'LEFT' or 'RIGHT'
  else
    for _, t in ipairs(S.threads) do
      for _, c in ipairs(t.comments) do
        if c.databaseId == id then path, side, line = t.path, t.diffSide, t.line end
      end
    end
  end
  local file = S.by_path[path]
  if not file then return notify('the link points at something that is not in this PR\'s diff', vim.log.levels.WARN) end
  if file.status == 'D' then side = 'LEFT' end
  show(path, side, tonumber(line) or diff.stops(file, side)[1] or 1)
end

local watcher, debounce
-- Reload when the agent writes to the review, and say so when it hands the turn back or closes it.
local function watch(log)
  if watcher then watcher:close() end -- close, not just stop: stopped handles still hold an fd
  watcher, debounce = vim.uv.new_fs_event(), debounce or vim.uv.new_timer()
  local function changed()
    if not S or S.log ~= log then return end
    local before, was_closed = S.review.last_submit, S.review.closed
    refresh()
    local last = S.review.last_submit
    if S.review.closed and not was_closed then
      notify(('%s closed the review'):format(S.review.agent_author or 'the agent'))
    elseif last and last.role == 'agent' and (not before or before.seq ~= last.seq) then
      notify(('%s submitted%s · your turn'):format(last.author, last.summary and (': ' .. last.summary) or ''))
    end
  end
  local function soon(ms)
    debounce:stop()
    debounce:start(ms, 0, vim.schedule_wrap(changed))
  end
  local ok, err = watcher:start(log, {}, function() soon(300) end)
  if not ok then notify("can't watch the review for the agent's changes (" .. tostring(err) .. '); use :Critique refresh', vim.log.levels.WARN) end
  soon(1000) -- the watch takes a moment to go live (macOS); catch anything written in that window
end

local cmds = {}
M.cmds = cmds

-- Everything after a review is loaded: autocmds, cwd, file list, decorations.
local function start(st)
  S = st
  local group = vim.api.nvim_create_augroup('critique', {})
  vim.api.nvim_create_autocmd('BufReadPost', { group = group, callback = function(ev) decorate(ev.buf) end })
  vim.api.nvim_create_autocmd('BufReadCmd', { group = group, pattern = 'critique://base/*', callback = function(ev) read_base(ev.buf) end })
  vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = set_highlights })
  set_highlights()
  vim.api.nvim_set_current_dir(S.dir)
  vim.cmd.checktime()
  cmds.files()
  if #S.files > 0 then vim.cmd.cfirst() end
  redraw()
end

-- A local review by handle (`<id>[@path][#n]`); with no handle, the one in this repo, or a new one.
local function open_local(handle)
  local cwd, log, n = vim.uv.cwd(), nil, nil
  if handle ~= '' then
    log, n = store.find(handle, cwd)
  else
    local reviews = store.list(cwd)
    if #reviews == 0 then
      local ok, root = pcall(store.git, cwd, 'rev-parse', '--show-toplevel')
      if not ok then error('not in a git repository; pass a PR URL or a review handle', 0) end
      local branch = store.git(root, 'branch', '--show-current')
      log = store.start(root, { title = branch ~= '' and branch or nil, author = vim.trim(vim.fn.system({ 'git', '-C', root, 'config', 'user.name' })), role = 'human' })
    else
      local r = pick(reviews, 'Open review', function(r) return r.id .. ' · ' .. r.title end)
      if not r then return end
      log = r.log
    end
  end
  local st = { log = log, overlay = true }
  st.dir = vim.uv.fs_realpath(log:match('^(.*)/%.critique/reviews/'))
  st.me = vim.trim(vim.fn.system({ 'git', '-C', st.dir, 'config', 'user.name' }))
  st.me = st.me ~= '' and st.me or os.getenv('USER') or 'me'
  st.git_dir = st.dir
  load_local(st)
  start(st)
  watch(log)
  for _, t in ipairs(S.threads) do
    if t.n == n then show(t.path, t.diffSide, t.line) end
  end
  local r, open = S.review, #vim.tbl_filter(function(t) return not t.isResolved end, S.threads)
  local turn = r.closed and 'closed' or r.turn == 'human' and 'your turn' or r.turn == 'agent' and "the agent's turn" or 'not submitted yet'
  local last = r.last_submit and r.last_submit.role == 'agent' and r.last_submit.summary
  local msg = ('%s · %s changed · %s · %s%s'):format(S.title, plural(#S.files, 'file'), plural(open, 'open thread'), turn,
    last and (' · ' .. r.last_submit.author .. ': ' .. last) or '')
  vim.schedule(function() notify(msg) end) -- after startup's first redraw, which would wipe it when opened via `nvim -c`
end

function cmds.open(o)
  local url = table.concat(o.fargs, ' ', 2) -- handles can contain spaces (a checkout path)
  local host, owner, name, number = url:match('^https?://([^/]+)/([^/]+)/([^/]+)/pull/(%d+)')
  if not owner then
    if url:match('^https?://') then error('usage: :Critique open https://<github host>/<owner>/<repo>/pull/<number>', 0) end
    return open_local(url)
  end
  local st = { host = host, owner = owner, name = name, number = tonumber(number), overlay = true, by_path = {} }
  notify(('fetching %s/%s#%s…'):format(owner, name, number))
  local pr = fetch_pr(st)

  local root = ('%s/critique/%s/%s/%s'):format(vim.fn.stdpath('cache'), host, owner, name)
  local git_dir, wt = root .. '/repo.git', root .. '/pr-' .. number
  if not vim.uv.fs_stat(git_dir) then
    notify('cloning (first time only)…')
    vim.fn.mkdir(root, 'p')
    -- Blobless: commits and trees now, file contents on demand. gh supplies credentials for private repos.
    gh.git(root, 'clone', '--bare', '--filter=blob:none', '--single-branch',
      '-c', 'credential.helper=', '-c', 'credential.helper=!gh auth git-credential',
      ('https://%s/%s/%s.git'):format(host, owner, name), git_dir)
  end
  gh.git(git_dir, 'fetch', '--no-tags', 'origin', pr.baseRefOid, pr.headRefOid)
  if vim.uv.fs_stat(wt) then
    gh.git(wt, 'checkout', '--detach', pr.headRefOid) -- refuses to clobber local edits
  else
    gh.git(git_dir, 'worktree', 'add', '--detach', wt, pr.headRefOid)
  end

  -- GitHub diffs against the merge base.
  st.git_dir, st.dir, st.head = git_dir, vim.uv.fs_realpath(wt), pr.headRefOid
  st.base = vim.trim(gh.git(git_dir, 'merge-base', pr.baseRefOid, pr.headRefOid))
  st.files = diff.parse(gh.git(git_dir, unpack(vim.list_extend(vim.list_slice(diff.GIT_ARGS), { st.base, st.head }))))
  for _, f in ipairs(st.files) do st.by_path[f.path] = f end
  st.title = ('#%d %s'):format(st.number, pr.title)
  if watcher then watcher:close() watcher = nil end
  start(st)
  goto_anchor(url)
  notify(('%s · %s changed'):format(S.title, plural(#S.files, 'file')))
end

function cmds.files()
  set_qf()
  vim.cmd('botright copen')
end

function cmds.comment(o)
  local path, side = here()
  writable()
  if vim.bo.modified then error('save or undo your edits first; comments are placed by line number', 0) end
  if o.range == 0 then
    local ts = threads_here()
    if #ts > 0 then
      local t = pick(ts, 'Open thread', thread_label)
      return t and edit({ thread = t })
    end
  end
  local file = S.by_path[path]
  local h = file and diff.hunk_of(file, o.line1, side)
  if not S.review and (not h or h ~= diff.hunk_of(file, o.line2, side)) then
    error('GitHub only accepts comments on lines inside one diff hunk', 0)
  end
  local multi = o.line1 < o.line2
  edit({ code = vim.api.nvim_buf_get_lines(0, o.line1 - 1, o.line2, false), anchor = {
    path = path, side = side, line = o.line2,
    startLine = multi and o.line1 or nil, startSide = multi and side or nil,
  } })
end

function cmds.delete()
  writable()
  local mine = {}
  for _, t in ipairs(threads_here()) do
    for _, c in ipairs(t.comments) do
      if c.viewerDidAuthor then mine[#mine + 1] = c end
    end
  end
  if #mine == 0 then error('none of your comments are on this line', 0) end
  local c = gh.await(vim.ui.select, mine, {
    prompt = 'Delete comment',
    format_item = function(c) return (c.state == 'PENDING' and '(pending) ' or '') .. first_line(c.body) end,
  })
  if not c then return end
  if S.review then
    store.append(S.log, { type = 'delete', id = c.id })
  else
    gh.mutate(S.host, 'deletePullRequestReviewComment', { id = c.id })
  end
  refresh()
  notify('comment deleted')
end

function cmds.resolve()
  writable()
  local ts = threads_here()
  if #ts == 0 then error('no thread on this line', 0) end
  local t = pick(ts, 'Resolve thread', thread_label)
  if not t then return end
  if S.review then
    store.append(S.log, { type = 'resolve', thread = t.id, resolved = not t.isResolved, author = S.me, role = 'human' })
  else
    gh.mutate(S.host, t.isResolved and 'unresolveReviewThread' or 'resolveReviewThread', { threadId = t.id })
  end
  refresh()
  notify(t.isResolved and 'thread unresolved' or 'thread resolved')
end

function cmds.submit()
  writable()
  local unsaved = vim.tbl_filter(function(b)
    return vim.api.nvim_buf_get_name(b):find('^critique://comment/') and vim.bo[b].modified
  end, vim.api.nvim_list_bufs())
  if #unsaved > 0 then
    error(("%s isn't saved: :w it (or :q! to discard it) first"):format(#unsaved == 1 and '1 comment' or (#unsaved .. ' comments')), 0)
  end
  if S.review then
    local drafts = #S.review.drafts
    local summary = gh.await(vim.ui.input, { prompt = 'Summary for the agent (optional): ' })
    if not summary then return end
    store.append(S.log, { type = 'submit', author = S.me, role = 'human', summary = summary ~= '' and summary or nil })
    refresh()
    return notify(("sent %s · the agent's turn"):format(plural(drafts, 'comment')))
  end
  local event = gh.await(vim.ui.select, { 'COMMENT', 'APPROVE', 'REQUEST_CHANGES' }, {
    prompt = 'Submit review as',
    format_item = function(e) return (e:lower():gsub('_', ' ')) end,
  })
  if not event then return end
  local body = gh.await(vim.ui.input, { prompt = 'Summary (optional): ' })
  if not body then return end
  body = body ~= '' and body or nil
  if S.review_id then
    gh.mutate(S.host, 'submitPullRequestReview', { pullRequestReviewId = S.review_id, event = event, body = body })
  else
    gh.mutate(S.host, 'addPullRequestReview', { pullRequestId = S.pr_id, commitOID = S.head, event = event, body = body })
  end
  refresh()
  notify('review submitted')
end

function cmds.toggle()
  S.overlay = not S.overlay
  redraw()
end

-- Permalink to the cursor line (or visual range) at the commit this buffer shows.
function cmds.link(o)
  local path, side = here()
  if S.review then error('links need a GitHub PR; this is a local review', 0) end
  local file = S.by_path[path]
  if side == 'LEFT' and file then path = file.old_path end
  local lines = o.line1 == o.line2 and ('L%d'):format(o.line1) or ('L%d-L%d'):format(o.line1, o.line2)
  local url = ('https://%s/%s/%s/blob/%s/%s#%s'):format(S.host, S.owner, S.name, side == 'LEFT' and S.base or S.head,
    (path:gsub('[^%w%-._~/]', function(c) return ('%%%02X'):format(c:byte()) end)), lines)
  vim.fn.setreg('"', url)
  if vim.fn.has('clipboard') == 1 then
    vim.fn.setreg('+', url)
    notify('copied ' .. url)
  else
    notify('no system clipboard; yanked to the " register: ' .. url)
  end
end

function cmds.help() vim.cmd.help('critique') end
function cmds.before() swap('LEFT') end
function cmds.after() swap('RIGHT') end
cmds.refresh = refresh

function M.command(o)
  local sub = o.fargs[1] or 'open' -- bare :Critique opens the local review in this repo
  if not cmds[sub] then return notify('unknown subcommand: ' .. sub, vim.log.levels.ERROR) end
  if not S and sub ~= 'open' and sub ~= 'help' then return notify('no review open; run :Critique open <url>', vim.log.levels.ERROR) end
  gh.async(cmds[sub])(o)
end

return M
