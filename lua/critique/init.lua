local gh = require('critique.gh')
local diff = require('critique.diff')
local store = require('critique.store')

local M = {}
M.defaults = {
  auto_suggest = true, -- :w in a review file posts your edits as suggestions instead of saving them
  footer = true, -- comments you post on GitHub end with "Made with critique.nvim"
}
M.config = vim.deepcopy(M.defaults)
-- This file's last change, as of loading it: :checkhealth compares, to catch an update that still needs a restart.
M.loaded = (vim.uv.fs_stat(debug.getinfo(1, 'S').source:sub(2)) or {}).mtime

-- require('critique').setup({ auto_suggest = false }), or lazy.nvim's `opts`. Optional: the defaults work as they are.
function M.setup(opts)
  M.config = vim.tbl_extend('force', M.config, opts or {})
end

local ns_diff = vim.api.nvim_create_namespace('critique.diff')
local ns_threads = vim.api.nvim_create_namespace('critique.threads')
local MARK = { github = '<!-- ▼ write below · :w saves to your pending review · :q closes ▼ -->',
  ['local'] = '<!-- ▼ write below · :w saves a draft · :q closes ▼ -->',
  live = '<!-- ▼ write below · :w sends it to the agent · :q closes ▼ -->' }
local S -- the open review

-- "Made with critique.nvim", with the logo as the c. Its alt text is the c, so a blocked image still reads right.
local FOOTER = '\n\n<sub>Made with <a href="https://github.com/BSchrift/critique.nvim"><img src="'
  .. 'https://raw.githubusercontent.com/BSchrift/critique.nvim/main/assets/icon-512.png" height="14" align="texttop" '
  .. 'alt="c">ritique.nvim</a></sub>'
-- A GitHub comment as you post it, with the footer (config.footer)...
local function signed(body) return M.config.footer and body .. FOOTER or body end
-- ...and as critique shows it, without (anyone's, any version's), so editing never stacks a second one.
local function unsigned(body) return (body:gsub('%s*<sub>[^\n]*critique%.nvim[^\n]*</sub>%s*$', '')) end

-- Files and threads come 100 a page (fetch_pr asks for the rest).
-- shortcut: 100 comments per thread, and your last review among the last 100; paginate if PRs outgrow that.
local PR_QUERY = [[
query($owner: String!, $name: String!, $number: Int!, $files: String, $reviewThreads: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      id title headRefOid baseRefOid
      reviews(states: PENDING, first: 1) { nodes { id } }
      submitted: reviews(last: 100, states: [APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED]) { nodes { viewerDidAuthor commit { oid } } }
      files(first: 100, after: $files) { nodes { path viewerViewedState } pageInfo { hasNextPage endCursor } }
      reviewThreads(first: 100, after: $reviewThreads) {
        nodes {
          id isResolved isOutdated path line originalLine diffSide
          comments(first: 100) { nodes { id databaseId body state viewerDidAuthor author { login } } }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}]]

-- shortcut: the last 100 comments, reviews, and checks.
local OVERVIEW_QUERY = [[
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      url body state isDraft reviewDecision baseRefName headRefName author { login }
      commits(last: 1) { nodes { commit { statusCheckRollup { state contexts(last: 100) { nodes {
        ... on CheckRun { name status conclusion }
        ... on StatusContext { context state }
      } } } } } }
      comments(last: 100) { nodes { author { login } body createdAt } }
      reviews(last: 100, states: [APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED]) { nodes { author { login } body state submittedAt } }
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

local SPINNER = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
-- An animated status line while a PR opens: the step, and git's own progress for it. It stops by itself when the
-- command that started it ends, even with an error.
local progress = {}
function progress.start(step)
  local co, timer, frame = coroutine.running(), vim.uv.new_timer(), 0
  progress.timer, progress.step, progress.detail = timer, step, nil
  timer:start(0, 100, vim.schedule_wrap(function()
    if progress.timer ~= timer or coroutine.status(co) == 'dead' then
      if not timer:is_closing() then timer:close() end
      return
    end
    frame = frame % #SPINNER + 1
    local text = ('%s critique: %s%s'):format(SPINNER[frame], progress.step, progress.detail and (' · ' .. progress.detail) or '')
    vim.api.nvim_echo({ { vim.fn.strcharpart(text, 0, math.max(vim.v.echospace, 20) - 1) } }, false, {})
  end))
end
function progress.set(step) progress.step, progress.detail = step, nil end
function progress.show(detail) progress.detail = detail end
function progress.stop() progress.timer = nil end

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

-- "#2 (3) · outdated · alice: Why + 0? · ⏳ claude is on it": the thread at a glance, inline and in :Critique threads.
local function thread_summary(t)
  local c = t.comments[1]
  local count = (t.n and ('#%d '):format(t.n) or '') .. ('(%d)'):format(#t.comments)
  local state = t.ack and (' · ⏳ ' .. t.ack .. ' is on it') or t.sent and ' · sent' or ''
  local text = c.body:match('^`+suggestion') and '💡 suggested a change' or first_line(c.body)
  return ('%s · %s%s: %s%s'):format(count, t.outdated and 'outdated · ' or '', login(c), text, state)
end

local function is_pending(t)
  return vim.iter(t.comments):any(function(c) return c.state == 'PENDING' end)
end

local function render_threads(buf, path, side)
  for _, t in ipairs(S.threads) do
    local lnum = thread_line(buf, t, path, side)
    if lnum then
      vim.api.nvim_buf_set_extmark(buf, ns_threads, lnum - 1, 0, {
        virt_text = { { (' %s %s'):format(t.isResolved and '✓' or '💬', thread_summary(t)),
          t.isResolved and 'CritiqueResolved' or is_pending(t) and 'CritiquePending' or 'CritiqueThread' } },
      })
    end
  end
end

-- The diff drawn on a file. With :Critique since on, the PR side shows only what changed since your last review.
local function shown(path, side)
  return (S.since and side == 'RIGHT' and S.since or S).by_path[path]
end

local function jump(dir)
  local path, side = buf_path(0)
  local file = shown(path, side)
  if not file then return end -- :Critique since turned off this file's changes
  local cur, last = vim.fn.line('.'), vim.fn.line('$')
  local stops = diff.stops(file, side)
  for i = dir > 0 and 1 or #stops, dir > 0 and #stops or 1, dir do
    local l = math.max(1, math.min(stops[i], last))
    if (l - cur) * dir > 0 then return vim.api.nvim_win_set_cursor(0, { l, 0 }) end
  end
end

local intercept_writes -- :w in review files, with auto_suggest (defined with the suggestions below)

local function decorate(buf)
  local path, side = buf_path(buf)
  if not path then return end
  vim.api.nvim_buf_clear_namespace(buf, ns_diff, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, ns_threads, 0, -1)
  local file = shown(path, side)
  if file and S.overlay then diff.render(buf, file, side, ns_diff) end
  render_threads(buf, path, side)
  if side == 'RIGHT' and M.config.auto_suggest then intercept_writes(buf) end
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
  -- lockmarks: otherwise the quickfix entries already pointing into this (empty) buffer shift down by its length.
  vim.g.critique_base = lines
  vim.cmd(('lockmarks call nvim_buf_set_lines(%d, 0, -1, v:false, g:critique_base)'):format(buf))
  vim.g.critique_base = nil
  vim.bo[buf].buftype, vim.bo[buf].modifiable, vim.bo[buf].modified = 'nofile', false, false
  vim.bo[buf].filetype = vim.filetype.match({ filename = path, buf = buf }) or ''
  decorate(buf)
end

local function fetch_pr(st)
  local vars, more, pr = { owner = st.owner, name = st.name, number = st.number }, { files = true, reviewThreads = true }, nil
  while next(more) do -- the next page of each list that has one; a finished list is asked for after its end (empty)
    local page = gh.gql(st.host, PR_QUERY, vars).repository.pullRequest
    pr = pr or vim.tbl_extend('force', page, { files = { nodes = {} }, reviewThreads = { nodes = {} } })
    for key in pairs(more) do
      vim.list_extend(pr[key].nodes, page[key].nodes)
      vars[key] = page[key].pageInfo.endCursor or vars[key]
      more[key] = page[key].pageInfo.hasNextPage or nil
    end
  end
  st.pr_id, st.review_id = pr.id, (pr.reviews.nodes[1] or {}).id
  st.viewed = {}
  for _, f in ipairs(pr.files.nodes) do st.viewed[f.path] = ({ VIEWED = 'viewed', DISMISSED = 'changed' })[f.viewerViewedState] end
  for _, r in ipairs(pr.submitted.nodes) do
    if r.viewerDidAuthor and r.commit then st.reviewed = r.commit.oid end -- your last review's commit, for :Critique since
  end
  st.threads = vim.tbl_map(function(t)
    t.comments, t.outdated = t.comments.nodes, t.isOutdated
    for _, c in ipairs(t.comments) do c.body = unsigned(c.body) end
    t.line = t.line or t.originalLine -- an outdated thread stays where its code was, as in local reviews
    return t
  end, pr.reviewThreads.nodes)
  return pr
end

-- What a viewed mark remembers in a local review: the file's diff, so a later change shows as "changed since viewed".
-- shortcut: binary files have no diff lines, so a change to one keeps its mark; hash the file if that matters.
local function fingerprint(f)
  local parts = { f.status, f.old_path or '' }
  for _, h in ipairs(f.hunks) do
    for _, l in ipairs(h.lines) do parts[#parts + 1] = l.kind .. l.text end
  end
  return vim.fn.sha256(table.concat(parts, '\n'))
end

-- A local review (see store.lua), in the same shape as GitHub's threads so the UI is shared.
local function load_local(st)
  local r = store.load(st.log, 'human')
  st.review, st.base, st.title = r, r.base, r.id .. ' · ' .. r.title
  st.files, st.by_path = diff.parse(store.diff(r)), {}
  for _, f in ipairs(st.files) do st.by_path[f.path] = f end
  st.viewed = {}
  for path, hash in pairs(r.viewed) do
    if st.by_path[path] then st.viewed[path] = fingerprint(st.by_path[path]) == hash and 'viewed' or 'changed' end
  end
  st.threads = vim.tbl_map(function(t)
    return { -- an outdated thread stays where its code was, so you can still read and answer it
      id = t.id, n = t.n, path = t.path, line = t.line or t.orig_line, outdated = t.outdated, isResolved = t.resolved,
      ack = t.ack and not t.resolved and not t.needs_agent and t.ack.author or nil, -- a newer comment of yours is waiting
      sent = r.live and t.needs_agent or nil, -- live: sent, but the agent hasn't picked it up yet
      diffSide = t.side == 'old' and 'LEFT' or 'RIGHT',
      comments = vim.tbl_map(function(c)
        return { id = c.id, body = c.body, state = c.pending and 'PENDING' or 'SUBMITTED', viewerDidAuthor = c.role == 'human', author = { login = c.author } }
      end, t.comments),
    }
  end, r.threads)
end

-- Where the file list takes you in a file: its first change (in a deleted file, on its old version).
local function first_change(f)
  local side = f.status == 'D' and 'LEFT' or 'RIGHT'
  return side, diff.stops(f, side)[1] or 1
end

-- Viewed files among those listed (with :Critique since on, the files changed since your last review), and how many are listed.
local function viewed_count()
  local files = (S.since or S).files
  return #vim.tbl_filter(function(f) return S.viewed[f.path] == 'viewed' end, files), #files
end

local function plural(n, word)
  return ('%d %s%s'):format(n, word, n == 1 and '' or 's')
end

-- The open threads, in file order. Once listed, a thread stays (marked resolved when it is) and new ones go at the
-- end, so the list doesn't shift under ]q while you work through it. :Critique threads starts it afresh.
local function thread_items()
  local order, by_id = {}, {}
  for i, f in ipairs(S.files) do order[f.path] = i end
  for _, t in ipairs(S.threads) do by_id[t.id] = t end
  local new = vim.tbl_filter(function(t) return not t.isResolved and not vim.tbl_contains(S.listed, t.id) end, S.threads)
  table.sort(new, function(a, b)
    local fa, fb = order[a.path] or math.huge, order[b.path] or math.huge
    if fa ~= fb then return fa < fb end
    if a.path ~= b.path then return a.path < b.path end
    return (a.line or 0) < (b.line or 0)
  end)
  for _, t in ipairs(new) do table.insert(S.listed, t.id) end
  local items, open, waiting = {}, 0, 0
  for _, id in ipairs(S.listed) do
    local t = by_id[id]
    if t then -- gone if all its comments were deleted
      local needs = not t.isResolved and not t.comments[#t.comments].viewerDidAuthor
      open, waiting = open + (t.isResolved and 0 or 1), waiting + (needs and 1 or 0)
      local base = t.diffSide == 'LEFT' or (S.by_path[t.path] or {}).status == 'D'
      table.insert(items, {
        filename = (base and 'critique://base/' or S.dir .. '/') .. t.path,
        lnum = t.line,
        text = (t.isResolved and '✓ ' or '') .. thread_summary(t)
          .. (t.isResolved and ' · resolved' or needs and ' · needs your reply' or is_pending(t) and ' · pending' or ''),
      })
    end
  end
  return items, S.title .. ' · ' .. plural(open, 'open thread')
    .. (waiting == 0 and '' or waiting == 1 and ' · 1 needs your reply' or (' · %d need your reply'):format(waiting))
end

-- The review's quickfix list: changed files, or with :Critique threads, open threads. `reset` starts at the top.
local function set_qf(reset)
  local items, title
  if S.list == 'threads' then
    items, title = thread_items()
  else
    items = vim.tbl_map(function(f)
      local side, lnum = first_change(f)
      return {
        filename = side == 'LEFT' and 'critique://base/' .. f.path or S.dir .. '/' .. f.path,
        lnum = lnum,
        text = (({ viewed = '✓ ', changed = '● ' })[S.viewed[f.path]] or '') .. ('%s  +%d -%d'):format(f.status, f.adds, f.dels),
      }
    end, (S.since or S).files)
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
    local n, total = viewed_count()
    title = S.title .. (S.since and ' · since your last review' or '') .. (n > 0 and (' · %d/%d viewed'):format(n, total) or '')
  end
  local idx = not reset and S.qf_id and vim.fn.getqflist({ id = S.qf_id, idx = 0 }).idx or 1
  local what = { id = S.qf_id, title = title, items = items, idx = math.max(1, math.min(idx, #items)) }
  -- Replace our own list in place, so it never pushes your other quickfix lists off the stack, and keep your place in it.
  if not (S.qf_id and vim.fn.setqflist({}, 'r', what) == 0) then
    what.id = nil
    vim.fn.setqflist({}, ' ', what)
    S.qf_id = vim.fn.getqflist({ id = 0 }).id
  end
end

-- Fetches commits for a PR: just those commits, without their history, in a repo critique set up that way, and
-- as a normal fetch in a full clone (made by critique before 0.4). Returns whether it worked, and git's error.
local function fetch(git_dir, revs, on_progress)
  local args = { 'fetch', '--progress', '--no-tags' }
  if vim.uv.fs_stat(git_dir .. '/critique-shallow') then table.insert(args, '--depth=1') end
  return gh.git_progress(git_dir, on_progress or function() end, vim.list_extend(args, { 'origin', unpack(revs) }))
end

-- Downloads the file contents of a commit, with progress. Checking it out would download them anyway, but silently.
-- git skips those it already has.
local function fetch_files(git_dir, rev, on_progress)
  local ids = {}
  for id in gh.git(git_dir, 'ls-tree', '-r', rev):gmatch(' blob (%x+)\t') do ids[#ids + 1] = id end
  if #ids == 0 then return true end -- with nothing to ask for, git would fetch every branch
  -- One string: given a list, vim.system writes each id separately, which blocks Neovim for seconds in a monorepo.
  return gh.git_progress(git_dir, on_progress, { 'fetch', '--progress', '--no-tags', '--no-write-fetch-head', '--stdin', 'origin' },
    table.concat(ids, '\n') .. '\n')
end

local function must(ok, err)
  if not ok then error(err, 0) end
end

-- Changes since your last review: since your last :Critique submit (local), or since the commit your last GitHub review was on.
local function load_since()
  local from = S.review and S.review.reviewed_tree or S.reviewed
  if not from then
    error(S.review and 'nothing to compare yet: this shows what changed after your next :Critique submit' or "you haven't reviewed this PR yet", 0)
  end
  local out
  if S.review then
    out = store.diff(S.review, from)
  else
    S.fetched = S.fetched or {} -- once per commit: refresh() calls this after every comment
    if not S.fetched[from] then
      if not fetch(S.git_dir, { from }) then
        error(("can't fetch %s, the commit of your last review; was it force-pushed away?"):format(from:sub(1, 7)), 0)
      end
      S.fetched[from] = true
    end
    out = gh.git(S.git_dir, unpack(vim.list_extend(vim.list_slice(diff.GIT_ARGS), { from, S.head })))
  end
  S.since = { files = diff.parse(out), by_path = {} }
  for _, f in ipairs(S.since.files) do S.since.by_path[f.path] = f end
end

local function refresh()
  if S.review then
    load_local(S) -- the agent may have changed files too
    vim.cmd.checktime()
  else
    fetch_pr(S)
  end
  if S.since then load_since() end -- your submit, or the agent's edits, change what "since" shows
  set_qf() -- also for viewed marks: a viewed file may have changed
  redraw()
end

local function status(r)
  local turn = r.closed and 'closed' or r.turn == 'human' and 'your turn' or r.turn == 'agent' and "the agent's turn" or 'not submitted yet'
  return turn .. (r.live and not r.closed and ' · live' or '')
end

local function writable()
  if S.review and S.review.closed then error('this review is closed', 0) end
end

local function ensure_review()
  S.review_id = S.review_id
    or gh.mutate(S.host, 'addPullRequestReview', { pullRequestId = S.pr_id, commitOID = S.head }, 'pullRequestReview { id }').pullRequestReview.id
  return S.review_id
end

-- Saves a comment: an edit of ctx.comment, a reply in ctx.thread, or a new thread at ctx.anchor (on ctx.code).
-- Returns whether it reopened a resolved thread.
local function post(ctx, body)
  writable()
  local reopens = S.review and ctx.thread and ctx.thread.isResolved and not ctx.comment -- a new reply on a resolved thread
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
    gh.mutate(S.host, 'updatePullRequestReviewComment', { pullRequestReviewCommentId = ctx.comment.id, body = signed(body) })
  elseif ctx.thread then
    local input = { pullRequestReviewThreadId = ctx.thread.id, pullRequestReviewId = ensure_review(), body = signed(body) }
    ctx.comment = gh.mutate(S.host, 'addPullRequestReviewThreadReply', input, 'comment { id }').comment
  else
    local input = vim.tbl_extend('force', ctx.anchor, { pullRequestReviewId = ensure_review(), body = signed(body) })
    local t = gh.mutate(S.host, 'addPullRequestReviewThread', input, 'thread { id comments(first: 1) { nodes { id } } }').thread
    if not t then error('GitHub rejected the comment', 0) end
    ctx.comment = t.comments.nodes[1]
  end
  return reopens
end

local function save(buf, ctx)
  local lines, at = vim.api.nvim_buf_get_lines(buf, 0, -1, false), nil
  for i = #lines, 1, -1 do
    if lines[i]:find('^<!%-%- ▼ write below') then at = i break end
  end
  if not at then error('keep the "<!-- ▼ write below … ▼ -->" line; your comment goes below it', 0) end
  local body = vim.trim(table.concat(lines, '\n', at + 1))
  if body == '' then error('comment is empty; nothing saved', 0) end
  local from = ctx.review -- reopening a review makes a new S: the same review is the same log, or the same PR
  if from ~= S and not (from.log and from.log == S.log or from.pr_id and from.host == S.host and from.pr_id == S.pr_id) then
    error(('this comment is for %s, which is no longer open: reopen it to save this comment, or :q! to drop it')
      :format(from.title), 0)
  end
  if ctx.anchor and from.head ~= S.head then -- its line number is in the PR as it was
    error("the PR has new commits since you started this comment, so its line may have moved: copy your text, :q!, and comment again", 0)
  end
  local reopens = post(ctx, body)
  if vim.api.nvim_buf_is_valid(buf) then vim.bo[buf].modified = false end
  refresh()
  local agent = S.review and S.review.agent_author or 'the agent'
  notify(not S.review and 'saved to your pending review'
    or (S.review.live and ('sent · %s starts on it once you pause; ⏳ shows when it does'):format(agent)
      or 'saved; the agent sees it after :Critique submit') .. (reopens and (' · reopened #' .. ctx.thread.n) or ''))
end

-- Opens a scratch markdown buffer: the thread so far, then your text below MARK. :w syncs to GitHub.
local function edit(ctx)
  ctx.review = S -- the comment belongs to this review, even if another one is opened before :w
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
  table.insert(lines, MARK[S.review and (S.review.live and 'live' or 'local') or 'github'])
  vim.list_extend(lines, ctx.comment and split(ctx.comment.body) or { '' })

  vim.cmd('botright 12new')
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(buf, 'critique://comment/' .. buf)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile, vim.bo[buf].filetype = 'acwrite', 'wipe', false, 'markdown'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.api.nvim_win_set_cursor(0, { #lines, 0 })
  -- Wait for the save (GitHub's API), so :wq closes the comment once it's saved, and leaves it open if it failed.
  vim.api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = function() gh.wait(function() save(buf, ctx) end) end })
end

local diff_text = vim.text and vim.text.diff or vim.diff -- vim.diff is deprecated from Neovim 0.12

-- Your unsaved edits in a review file, one per changed block, each as a suggestion on lines of the file on disk.
-- An insertion goes with the line above it (or below, at the top): GitHub anchors suggestions on existing lines.
local function edits(buf, path)
  local old = store.read_lines(S.dir .. '/' .. path) or {}
  local new = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local file = S.by_path[path]
  return vim.tbl_map(function(h)
    local sa, ca, sb, cb = unpack(h)
    local e = { hunk = h, orig = vim.list_slice(old, sa, sa + ca - 1), lines = vim.list_slice(new, sb, sb + cb - 1), first = sa, show = {} }
    for _, l in ipairs(e.orig) do table.insert(e.show, '- ' .. l) end
    for _, l in ipairs(e.lines) do table.insert(e.show, '+ ' .. l) end
    if ca == 0 then
      local at = math.max(sa, 1)
      e.first = at
      table.insert(e.lines, sa >= 1 and 1 or #e.lines + 1, old[at])
      table.insert(e.show, sa >= 1 and 1 or #e.show + 1, '  ' .. (old[at] or ''))
    end
    e.last = math.max(e.first, sa + ca - 1)
    e.code = vim.list_slice(old, e.first, e.last)
    local h1 = file and diff.hunk_of(file, e.first, 'RIGHT')
    e.ok = #old > 0 and (S.review ~= nil or (h1 ~= nil and h1 == diff.hunk_of(file, e.last, 'RIGHT')))
    return e
  end, diff_text(table.concat(old, '\n') .. '\n', table.concat(new, '\n') .. '\n', { result_type = 'indices' }))
end

local function suggestion_body(lines)
  local fence = 3 -- longer than any run of backticks in the code, so the code can't end the block
  for _, l in ipairs(lines) do
    for run in l:gmatch('`+') do fence = math.max(fence, #run + 1) end
  end
  fence = ('`'):rep(fence)
  return fence .. 'suggestion\n' .. table.concat(vim.list_extend(vim.list_slice(lines), { fence }), '\n')
end

-- Posts the edits that can be suggestions, like comments, and takes them out of the buffer; the rest stay.
local function post_suggestions(buf, path, list)
  local posted, shift = 0, 0
  for _, e in ipairs(list) do
    if e.ok then
      local multi = e.first < e.last
      post({ code = e.code, anchor = { path = path, side = 'RIGHT', line = e.last, startLine = multi and e.first or nil,
        startSide = multi and 'RIGHT' or nil } }, suggestion_body(e.lines))
      posted = posted + 1
      local _, _, sb, cb = unpack(e.hunk) -- put back the file's lines; `shift` keeps later blocks' line numbers right
      local from = (cb > 0 and sb - 1 or sb) + shift
      vim.api.nvim_buf_set_lines(buf, from, from + cb, false, e.orig)
      shift = shift + #e.orig - cb
    end
  end
  if posted == #list then vim.bo[buf].modified = false end
  refresh()
  local what, them, agent = plural(posted, 'suggestion'), posted == 1 and 'it' or 'them', S.review and S.review.agent_author or 'the agent'
  notify(not S.review and what .. ' saved to your pending review'
    or S.review.live and ('sent %s · %s starts on %s once you pause'):format(what, agent, them)
    or ('saved %s; the agent sees %s after :Critique submit'):format(what, them))
end

local asking, waiting = false, {} -- one window at a time; :wa queues the other files

-- Asks, in a scrollable floating window, whether to post a file's edits as suggestions: y posts them, n cancels.
local function suggest(buf)
  if asking then
    if not vim.tbl_contains(waiting, buf) then table.insert(waiting, buf) end
    return
  end
  local path = buf_path(buf)
  local list = edits(buf, path)
  if #list == 0 then
    vim.bo[buf].modified = false -- edited back to what's on disk
    return notify('no edits to suggest in ' .. path)
  end
  local ok = #vim.tbl_filter(function(e) return e.ok end, list)
  local lines = {}
  for _, e in ipairs(list) do
    if #lines > 0 then table.insert(lines, '') end
    table.insert(lines, ('%s:%s%s'):format(path, e.first == e.last and e.first or (e.first .. '-' .. e.last),
      e.ok and '' or " · can't suggest here: not in the PR's diff (stays in the file)"))
    vim.list_extend(lines, e.show)
  end
  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, lines)
  vim.bo[fbuf].filetype, vim.bo[fbuf].modifiable, vim.bo[fbuf].bufhidden = 'diff', false, 'wipe'
  local width = 56
  for _, l in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(l) + 2) end
  width = math.min(width, vim.o.columns - 4)
  local height = math.max(1, math.min(#lines, vim.o.lines - 8))
  local win = vim.api.nvim_open_win(fbuf, true, {
    relative = 'editor', width = width, height = height, style = 'minimal', border = 'rounded',
    row = math.floor((vim.o.lines - height) / 2) - 1, col = math.floor((vim.o.columns - width) / 2),
    title = ok == 0 and " Can't suggest these " or (' Suggest %s? '):format(ok == 1 and 'this change' or ok .. ' changes'),
    title_pos = 'center', footer = (ok == 0 and ' n close ' or ' y post as suggestions · n cancel ') .. (height < #lines and '· j/k scroll ' or ''),
    footer_pos = 'center',
  })
  asking = true
  local function finish(yes)
    if not asking then return end
    asking = false
    pcall(vim.api.nvim_win_close, win, true)
    -- Wait for the post, as comment saves do: typing meanwhile would move the lines it then puts back.
    if yes and ok > 0 then gh.wait(function() post_suggestions(buf, path, list) end) end
    local nxt = table.remove(waiting, 1)
    if nxt and vim.api.nvim_buf_is_valid(nxt) then vim.schedule(function() suggest(nxt) end) end
  end
  vim.keymap.set('n', 'y', function() finish(true) end, { buffer = fbuf, nowait = true })
  for _, key in ipairs({ 'n', 'q', '<Esc>' }) do vim.keymap.set('n', key, function() finish(false) end, { buffer = fbuf, nowait = true }) end
  vim.api.nvim_create_autocmd('BufLeave', { buffer = fbuf, once = true, callback = function() vim.schedule(function() finish(false) end) end })
end

local hinted = false -- said once why a save from a timer did nothing

-- With auto_suggest on, :w in a review file asks to post your edits as suggestions instead of writing the file.
local function on_write(ev)
  local buf, target = ev.buf, vim.fn.fnamemodify(ev.file, ':p')
  if target ~= vim.api.nvim_buf_get_name(buf) or (S.review and vim.v.cmdbang == 1) then
    -- :w to another file, or :w! in a local review (you editing the agent's files yourself): a normal write, which
    -- runs your other write autocmds (formatters) since this one is nested.
    vim.api.nvim_clear_autocmds({ group = 'critique', buffer = buf, event = 'BufWriteCmd' })
    local ok, err = pcall(vim.cmd, ('write%s%s %s'):format(vim.v.cmdbang == 1 and '!' or '', vim.v.cmdarg, vim.fn.fnameescape(target)))
    intercept_writes(buf)
    if not ok then error(err, 0) end
  elseif vim.fn.state():find('S') then -- a save you made; an auto-save timer (no S) leaves your edits alone
    vim.schedule(function() suggest(buf) end)
  elseif not hinted then
    hinted = true
    notify(('ignored a save of %s from a timer or plugin (auto-save?), so your edits stay unsaved: in a review, '
      .. 'a :w you type offers them as suggestions, as does :Critique suggest'):format(buf_path(buf)))
  end
end

function intercept_writes(buf)
  vim.api.nvim_clear_autocmds({ group = 'critique', buffer = buf, event = 'BufWriteCmd' })
  vim.api.nvim_create_autocmd('BufWriteCmd', { group = 'critique', buffer = buf, nested = true, callback = on_write })
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
  -- Announces the agent's events since the last announcement. Only this advances S.announced, so your own
  -- saves (which refresh too) can't swallow an announcement.
  local function changed()
    if not S or S.log ~= log then return end
    refresh()
    local events = store.events(log)
    local n, parts, who, submit, closed = {}, {}, nil, nil, false
    for _, t in ipairs(S.threads) do n[t.id] = t.n end
    for i = S.announced + 1, #events do
      local ev = events[i]
      if ev.role == 'agent' then
        who = ev.author or who
        if ev.type == 'submit' then submit = ev
        elseif ev.type == 'close' then closed = true
        elseif S.review.live and n[ev.thread] then -- live: say what it did, as it does it (else drafts stay private)
          table.insert(parts, ev.type == 'ack' and ('is on #' .. n[ev.thread])
            or ev.type == 'resolve' and ((ev.resolved and 'resolved #' or 'reopened #') .. n[ev.thread])
            or ev.type == 'comment' and (ev.thread == ev.id and 'commented on #' or 'replied on #') .. n[ev.thread] or nil)
        end
      end
    end
    S.announced = #events
    who = who or S.review.agent_author or 'the agent'
    if closed then
      notify(('%s closed the review'):format(who))
    elseif submit then
      notify(('%s submitted%s · your turn%s'):format(submit.author, submit.summary and (': ' .. submit.summary) or '',
        S.review.reviewed_tree and ' · :Critique since shows what changed' or ''))
    elseif #parts > 0 then
      notify(('%s %s'):format(who, table.concat(vim.fn.uniq(parts), ', ')))
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
    local cache = (vim.uv.fs_realpath(vim.fn.stdpath('cache')) or vim.fn.stdpath('cache')) .. '/critique/'
    if vim.startswith(vim.uv.fs_realpath(cwd) or cwd, cache) then
      error("this folder is critique's checkout of a GitHub PR: :Critique open <PR url> reopens it, and local reviews go in your own repo", 0)
    end
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
  st.announced = #store.events(log) -- announce only what happens from now on
  start(st)
  watch(log)
  for _, t in ipairs(S.threads) do
    if t.n == n then show(t.path, t.diffSide, t.line) end
  end
  local r, open = S.review, #vim.tbl_filter(function(t) return not t.isResolved end, S.threads)
  local turn = status(r)
  local last = r.last_submit and r.last_submit.role == 'agent' and r.last_submit.summary
  local msg = ('%s · %s changed · %s · %s%s'):format(S.title, plural(#S.files, 'file'), plural(open, 'open thread'), turn,
    last and (' · ' .. r.last_submit.author .. ': ' .. last) or '')
  vim.schedule(function() notify(msg) end) -- after startup's first redraw, which would wipe it when opened via `nvim -c`
end

-- Where your edits in a PR's checkout went when they were in the way of its new commits.
local function stash_note(files, wt)
  return ("your edits to %s in the PR's checkout were in the way of its new commits, so they're stashed. "
    .. 'To get them back: git -C %s stash pop'):format(#files <= 3 and table.concat(files, ', ') or plural(#files, 'file'),
    vim.fn.shellescape(wt))
end

function cmds.open(o)
  local url = table.concat(o.fargs, ' ', 2) -- handles can contain spaces (a checkout path)
  local host, owner, name, number = url:match('^https?://([^/]+)/([^/]+)/([^/]+)/pull/(%d+)')
  if not owner then
    if url:match('^https?://') then error('usage: :Critique open https://<github host>/<owner>/<repo>/pull/<number>', 0) end
    return open_local(url)
  end
  local st = { host = host, owner = owner, name = name, number = tonumber(number), overlay = true, by_path = {} }
  progress.start(('opening %s/%s#%s'):format(owner, name, number))
  local root = ('%s/critique/%s/%s/%s'):format(vim.fn.stdpath('cache'), host, owner, name)
  local git_dir, wt = root .. '/repo.git', root .. '/pr-' .. number
  if not vim.uv.fs_stat(git_dir) then
    -- A repo of just the commits reviews need, without their history, and file contents only once they're used.
    -- gh supplies the credentials for private repos. Set up under another name, so a half-made one is never used.
    local new = git_dir .. '.new'
    vim.fn.mkdir(root, 'p')
    vim.fn.delete(new, 'rf')
    gh.git(root, 'init', '--quiet', '--bare', new)
    gh.git(new, 'remote', 'add', 'origin', ('https://%s/%s/%s.git'):format(host, owner, name))
    for _, kv in ipairs({ { 'remote.origin.promisor', 'true' }, { 'remote.origin.partialclonefilter', 'blob:none' },
      { 'credential.helper', '' }, { 'credential.helper', '!gh auth git-credential' } }) do
      gh.git(new, 'config', '--add', kv[1], kv[2])
    end
    vim.fn.writefile({}, new .. '/critique-shallow')
    assert(vim.uv.fs_rename(new, git_dir))
  end
  -- The PR from GitHub's API, and meanwhile its head commit.
  local pr = gh.all({
    function() return fetch_pr(st) end,
    function() must(fetch(git_dir, { ('refs/pull/%d/head'):format(st.number) }, progress.show)) end,
  })
  -- Never ask git whether it has a commit (cat-file -e): in a partial clone, a missing one is then downloaded with
  -- its whole history. Compare with what was fetched, or just fetch: git skips commits it already has.
  if vim.trim(gh.git(git_dir, 'rev-parse', 'FETCH_HEAD')) ~= pr.headRefOid then
    must(fetch(git_dir, { pr.headRefOid }, progress.show)) -- pushed to a moment ago
  end
  -- The files, and meanwhile the merge base that GitHub diffs against (git fetches run one at a time: they lock).
  progress.set('downloading the files')
  local fresh = not vim.uv.fs_stat(wt)
  st.base = gh.all({
    function() return gh.merge_base(host, owner, name, pr.baseRefOid, pr.headRefOid) end,
    function()
      if fresh then
        gh.git(git_dir, 'worktree', 'prune') -- forget a checkout folder you deleted, or git won't make it again
        gh.git(git_dir, 'worktree', 'add', '--quiet', '--no-checkout', '--detach', wt, pr.headRefOid)
      end
      must(fetch_files(git_dir, pr.headRefOid, progress.show))
      progress.set('checking out the files')
      local ok, err = gh.git_progress(wt, progress.show, { 'checkout', '--progress', '--detach', pr.headRefOid })
      local edited = not ok and not fresh and vim.tbl_map(function(l) return l:sub(4) end, -- "XY path"
        vim.split(gh.git(wt, 'status', '--porcelain', '--untracked-files=all'), '\n', { trimempty = true }))
      if edited and #edited > 0 then
        -- Edits in the checkout are in the way of the new commits (saved with auto_suggest off, by an auto-save
        -- plugin, or by critique before 0.2). Stash them, new files too, so nothing is lost, and try again.
        gh.git(wt, 'stash', 'push', '--include-untracked', '-m', ('critique: your edits, set aside to reopen PR #%d'):format(st.number))
        st.stashed = edited
        ok, err = gh.git_progress(wt, progress.show, { 'checkout', '--progress', '--detach', pr.headRefOid })
        if not ok then err = err .. '\n' .. stash_note(edited, wt) end
      end
      must(ok, err)
    end,
  })
  must(fetch(git_dir, { st.base }))

  progress.set('computing the diff')
  st.git_dir, st.dir, st.head = git_dir, vim.uv.fs_realpath(wt), pr.headRefOid
  st.files = diff.parse(gh.git(git_dir, unpack(vim.list_extend(vim.list_slice(diff.GIT_ARGS), { st.base, st.head }))))
  for _, f in ipairs(st.files) do st.by_path[f.path] = f end
  st.title = ('#%d %s'):format(st.number, pr.title)
  if watcher then watcher:close() watcher = nil end
  progress.stop()
  start(st)
  goto_anchor(url)
  notify(('%s · %s changed%s'):format(S.title, plural(#S.files, 'file'),
    S.reviewed and S.reviewed ~= S.head and ' · new commits since your last review: :Critique since' or ''))
  if st.stashed then notify(stash_note(st.stashed, wt), vim.log.levels.WARN) end
end

-- Shows the review's list of files or threads, even when another quickfix list is the current one.
local function open_list(kind)
  S.list = kind
  if kind == 'threads' then S.listed = {} end
  set_qf(true)
  vim.cmd(('silent %dchistory'):format(vim.fn.getqflist({ id = S.qf_id, nr = 0 }).nr))
  vim.cmd('botright copen')
end

function cmds.files() open_list('files') end

function cmds.threads()
  open_list('threads')
  if #vim.fn.getqflist() == 0 then return notify('no open threads') end
  vim.cmd.cfirst()
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
    local ok, tree = pcall(store.snapshot, S.dir) -- what you reviewed, for :Critique since; never block a submit on it
    store.append(S.log, { type = 'submit', author = S.me, role = 'human', summary = summary ~= '' and summary or nil, tree = ok and tree or nil })
    refresh()
    if S.review.live then -- the comments already went out as they were saved
      return notify(("told %s: that's all for now"):format(S.review.agent_author or 'the agent'))
    end
    return notify(("sent %s · the agent's turn"):format(plural(drafts, 'comment')))
  end
  local event = gh.await(vim.ui.select, { 'COMMENT', 'APPROVE', 'REQUEST_CHANGES' }, {
    prompt = 'Submit review as',
    format_item = function(e) return (e:lower():gsub('_', ' ')) end,
  })
  if not event then return end
  local body = gh.await(vim.ui.input, { prompt = 'Summary (optional): ' })
  if not body then return end
  body = body ~= '' and signed(body) or nil
  if S.review_id then
    gh.mutate(S.host, 'submitPullRequestReview', { pullRequestReviewId = S.review_id, event = event, body = body })
  else
    gh.mutate(S.host, 'addPullRequestReview', { pullRequestId = S.pr_id, commitOID = S.head, event = event, body = body })
  end
  refresh()
  notify('review submitted')
end

-- Your edits in this file, as suggestions: the same as :w with auto_suggest on.
function cmds.suggest()
  local _, side = here()
  if side ~= 'RIGHT' then error('suggestions go on the changed version of the file; :Critique after', 0) end
  suggest(vim.api.nvim_get_current_buf())
end

-- Toggles between all of the changes and only those since your last review.
function cmds.since()
  if S.since then
    S.since = nil
  else
    load_since()
    if #S.since.files == 0 then
      S.since = nil
      return notify('nothing changed since your last review')
    end
  end
  open_list('files')
  redraw()
  if S.since then vim.cmd.cfirst() end
  notify(S.since and ('%s changed since your last review · :Critique since again shows all changes'):format(plural(#S.since.files, 'file'))
    or 'showing all changes')
end

-- Marks the file you're in (or, in the file list, the one under the cursor) viewed, then moves on to the next
-- unviewed one. On a viewed file, unmarks it. GitHub: the same "Viewed" checkbox as on the website.
function cmds.viewed()
  writable()
  local in_list, path = vim.bo.buftype == 'quickfix', nil
  if in_list then
    if vim.fn.getqflist({ id = 0 }).id ~= S.qf_id then error("this isn't the review's file list; :Critique files opens it", 0) end
    local item = vim.fn.getqflist()[vim.fn.line('.')]
    path = item and buf_path(item.bufnr)
  else
    path = here()
  end
  local file = S.by_path[path]
  if not file then error('not a changed file in this review', 0) end
  local on = S.viewed[path] ~= 'viewed'
  if S.review then
    store.append(S.log, { type = 'viewed', path = path, viewed = on, hash = on and fingerprint(file) or nil, author = S.me, role = 'human' })
  else
    gh.mutate(S.host, on and 'markFileAsViewed' or 'unmarkFileAsViewed', { pullRequestId = S.pr_id, path = path })
  end
  S.viewed[path] = on and 'viewed' or nil
  set_qf()
  local n, total = viewed_count()
  if not on then return notify(('not viewed: %s · %d/%d viewed'):format(path, n, total)) end
  if n == total then return notify(('all %s viewed · :Critique submit'):format(plural(total, 'file'))) end
  local files = (S.since or S).files
  local at = vim.iter(ipairs(files)):find(function(_, f) return f.path == path end) or 0
  for k = 1, #files do
    local i = (at + k - 1) % #files + 1
    if S.viewed[files[i].path] ~= 'viewed' then
      if S.list == 'files' then vim.fn.setqflist({}, 'a', { id = S.qf_id, idx = i }) end -- so :cnext carries on from there
      if not in_list then
        show(files[i].path, first_change(files[i]))
      elseif S.list == 'files' then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
      end
      break
    end
  end
  notify(('%d/%d viewed'):format(n, total))
end

local FAILED = { failure = true, error = true, timed_out = true, cancelled = true, startup_failure = true, action_required = true }

-- What the review is about and its conversation, in a read-only markdown buffer.
function cmds.overview()
  local lines, entries = { '# ' .. S.title }, {}
  if S.review then
    local r = S.review
    table.insert(lines, ('base `%s` (%s) · %s'):format(r.base_ref, r.base:sub(1, 7), status(r)))
    for _, ev in ipairs(store.events(S.log)) do
      if ev.type == 'submit' then table.insert(entries, { who = (ev.author or ev.role) .. ' submitted', at = ev.at, body = ev.summary or '' }) end
    end
  else
    local pr = gh.gql(S.host, OVERVIEW_QUERY, { owner = S.owner, name = S.name, number = S.number }).repository.pullRequest
    local checks = vim.tbl_get(pr, 'commits', 'nodes', 1, 'commit', 'statusCheckRollup')
    vim.list_extend(lines, {
      ('%s wants to merge `%s` into `%s` · %s%s'):format(login(pr), pr.headRefName, pr.baseRefName, pr.state:lower(), pr.isDraft and ' · draft' or ''),
      pr.url, '',
    })
    if pr.reviewDecision then table.insert(lines, 'Review: ' .. pr.reviewDecision:lower():gsub('_', ' ')) end
    local passed, skipped, rest = 0, 0, {} -- like GitHub: count what passed, list the rest
    for _, c in ipairs(checks and checks.contexts.nodes or {}) do
      local result = (c.conclusion or c.state or c.status):lower()
      if result == 'success' then passed = passed + 1
      elseif result == 'skipped' or result == 'neutral' then skipped = skipped + 1
      else table.insert(rest, ('- %s %s (%s)'):format(FAILED[result] and '✗' or '•', c.name or c.context, (result:gsub('_', ' ')))) end
    end
    table.insert(lines, checks and ('Checks: %s · %d passed%s'):format(checks.state:lower(), passed, skipped > 0 and (', ' .. skipped .. ' skipped') or '')
      or 'Checks: none')
    vim.list_extend(lines, rest)
    vim.list_extend(lines, { '', '## Description', '' })
    vim.list_extend(lines, pr.body ~= '' and split(pr.body) or { '_No description._' })
    for _, c in ipairs(pr.comments.nodes) do table.insert(entries, { who = login(c), at = c.createdAt, body = unsigned(c.body) }) end
    for _, r in ipairs(pr.reviews.nodes) do
      local body = unsigned(r.body)
      if body ~= '' or r.state ~= 'COMMENTED' then -- a bare COMMENTED review is just its threads, which are on the code
        local verdict = ({ APPROVED = ' approved', CHANGES_REQUESTED = ' requested changes', DISMISSED = ' (dismissed)' })[r.state] or ''
        table.insert(entries, { who = login(r) .. verdict, at = r.submittedAt, body = body })
      end
    end
    table.sort(entries, function(a, b) return a.at < b.at end)
  end
  vim.list_extend(lines, { '', '## Conversation' })
  if #entries == 0 then vim.list_extend(lines, { '', '_Nothing yet._' }) end
  for _, e in ipairs(entries) do
    vim.list_extend(lines, { '', ('### %s · %s'):format(e.who, e.at:sub(1, 10)) })
    if e.body ~= '' then vim.list_extend(vim.list_extend(lines, { '' }), split(e.body)) end
  end
  local old = vim.fn.bufnr('critique://overview')
  if old ~= -1 then vim.api.nvim_buf_delete(old, { force = true }) end
  vim.cmd('topleft new')
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(buf, 'critique://overview')
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile, vim.bo[buf].filetype = 'nofile', 'wipe', false, 'markdown'
  vim.bo[buf].modifiable = false
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

-- Live: comments go to the agent as you save them, instead of waiting for :Critique submit.
function cmds.live()
  if not S.review then error('live mode is for local reviews with an agent', 0) end
  writable()
  local on, drafts = not S.review.live, #S.review.drafts
  store.append(S.log, { type = 'live', live = on, author = S.me, role = 'human' })
  refresh()
  notify(on and ('live: your comments reach the agent as you save them%s'):format(drafts > 0 and (' · sent your ' .. plural(drafts, 'draft')) or '')
    or 'live off: comments are drafts until :Critique submit')
end

function cmds.help() vim.cmd.help('critique') end
function cmds.before() swap('LEFT') end
function cmds.after() swap('RIGHT') end
cmds.refresh = refresh

function M.command(o)
  local sub = o.fargs[1] or (S and 'comment' or 'help') -- bare :Critique: comment in a review, else the help
  if not cmds[sub] then return notify('unknown subcommand: ' .. sub, vim.log.levels.ERROR) end
  if not S and sub ~= 'open' and sub ~= 'help' then return notify('no review open; run :Critique open <url>', vim.log.levels.ERROR) end
  gh.async(cmds[sub])(o)
end

return M
