local gh = require('critique.gh')
local diff = require('critique.diff')

local M = {}
local ns_diff = vim.api.nvim_create_namespace('critique.diff')
local ns_threads = vim.api.nvim_create_namespace('critique.threads')
local MARK = '<!-- ▼ write below · :w saves to your pending review · :q closes ▼ -->'
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
  },
  light = {
    CritiqueAdd = { bg = '#e6ffec' }, CritiqueAddWord = { bg = '#abf2bc' }, CritiqueAddSign = { fg = '#1a7f37' },
    CritiqueDelete = { bg = '#ffebe9' }, CritiqueDeleteWord = { bg = '#ffcecb' }, CritiqueDeleteSign = { fg = '#cf222e' },
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
    lnum = side == 'RIGHT' and file and file.anchor_left[t.line]
  end
  return lnum and math.min(lnum, vim.api.nvim_buf_line_count(buf))
end

local function render_threads(buf, path, side)
  for _, t in ipairs(S.threads) do
    local lnum = thread_line(buf, t, path, side)
    if lnum then
      local pending = vim.iter(t.comments):any(function(c) return c.state == 'PENDING' end)
      local c = t.comments[1]
      local text = (' %s %d · %s: %s'):format(t.isResolved and '✓' or '💬', #t.comments, login(c), first_line(c.body))
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

local function refresh()
  fetch_pr(S)
  redraw()
end

local function ensure_review()
  S.review_id = S.review_id
    or gh.mutate(S.host, 'addPullRequestReview', { pullRequestId = S.pr_id, commitOID = S.head }, 'pullRequestReview { id }').pullRequestReview.id
  return S.review_id
end

local function save(buf, ctx)
  local lines, at = vim.api.nvim_buf_get_lines(buf, 0, -1, false), nil
  for i = #lines, 1, -1 do
    if lines[i] == MARK then at = i break end
  end
  if not at then error('keep the "' .. MARK .. '" line; your comment goes below it', 0) end
  local body = vim.trim(table.concat(lines, '\n', at + 1))
  if body == '' then error('comment is empty; nothing saved', 0) end
  if ctx.comment then
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
  notify('saved to your pending review')
end

-- Opens a scratch markdown buffer: the thread so far, then your text below MARK. :w syncs to GitHub.
local function edit(ctx)
  local comments = ctx.thread and ctx.thread.comments or {}
  for _, c in ipairs(comments) do
    if c.viewerDidAuthor and c.state == 'PENDING' then ctx.comment = c end
  end
  local where = ctx.thread or ctx.anchor
  local lines = { ('<!-- PR #%d · %s:%d -->'):format(S.number, where.path, where.line), '' }
  for _, c in ipairs(comments) do
    if c ~= ctx.comment then
      table.insert(lines, ('<!-- @%s%s -->'):format(login(c), c.state == 'PENDING' and ' (pending)' or ''))
      vim.list_extend(lines, split(c.body))
      table.insert(lines, '')
    end
  end
  table.insert(lines, MARK)
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
  return login(t.comments[1]) .. ': ' .. first_line(t.comments[1].body)
end

local function swap(to)
  local path, side = here()
  if side == to then return end
  local file, lnum = S.by_path[path], vim.fn.line('.')
  if file then lnum = diff.map_line(file, lnum, side == 'RIGHT' and 'new' or 'old', to == 'RIGHT' and 'new' or 'old') end
  vim.cmd.edit(vim.fn.fnameescape(to == 'LEFT' and 'critique://base/' .. path or S.dir .. '/' .. path))
  pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
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
  vim.cmd.edit(vim.fn.fnameescape(side == 'LEFT' and 'critique://base/' .. path or S.dir .. '/' .. path))
  pcall(vim.api.nvim_win_set_cursor, 0, { tonumber(line) or diff.stops(file, side)[1] or 1, 0 })
  vim.cmd('normal! zz')
end

local cmds = {}
M.cmds = cmds

function cmds.open(o)
  local url = o.fargs[2] or ''
  local host, owner, name, number = url:match('^https?://([^/]+)/([^/]+)/([^/]+)/pull/(%d+)')
  if not owner then error('usage: :Critique open https://<github host>/<owner>/<repo>/pull/<number>', 0) end
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

  -- GitHub diffs against the merge base, with 3 lines of context; ignore user config that changes hunks.
  st.git_dir, st.dir, st.head = git_dir, vim.uv.fs_realpath(wt), pr.headRefOid
  st.base = vim.trim(gh.git(git_dir, 'merge-base', pr.baseRefOid, pr.headRefOid))
  st.files = diff.parse(gh.git(git_dir, '-c', 'core.quotepath=false', '-c', 'diff.suppressBlankEmpty=false',
    'diff', '--no-color', '--no-ext-diff', '--diff-algorithm=myers', '-M', '-U3', '--src-prefix=a/', '--dst-prefix=b/',
    st.base, st.head))
  for _, f in ipairs(st.files) do st.by_path[f.path] = f end
  st.title = ('#%d %s'):format(st.number, pr.title)
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
  goto_anchor(url)
  notify(('%s · %d files changed'):format(S.title, #S.files))
end

function cmds.files()
  vim.fn.setqflist({}, ' ', {
    title = S.title,
    items = vim.tbl_map(function(f)
      local side = f.status == 'D' and 'LEFT' or 'RIGHT'
      return {
        filename = side == 'LEFT' and 'critique://base/' .. f.path or S.dir .. '/' .. f.path,
        lnum = diff.stops(f, side)[1] or 1,
        text = ('%s  +%d -%d'):format(f.status, f.adds, f.dels),
      }
    end, S.files),
  })
  vim.cmd('botright copen')
end

function cmds.comment(o)
  local path, side = here()
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
  if not h or h ~= diff.hunk_of(file, o.line2, side) then
    error('GitHub only accepts comments on lines inside one diff hunk', 0)
  end
  local multi = o.line1 < o.line2
  edit({ anchor = {
    path = path, side = side, line = o.line2,
    startLine = multi and o.line1 or nil, startSide = multi and side or nil,
  } })
end

function cmds.delete()
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
  gh.mutate(S.host, 'deletePullRequestReviewComment', { id = c.id })
  refresh()
  notify('comment deleted')
end

function cmds.resolve()
  local ts = threads_here()
  if #ts == 0 then error('no thread on this line', 0) end
  local t = pick(ts, 'Resolve thread', thread_label)
  if not t then return end
  gh.mutate(S.host, t.isResolved and 'unresolveReviewThread' or 'resolveReviewThread', { threadId = t.id })
  refresh()
  notify(t.isResolved and 'thread unresolved' or 'thread resolved')
end

function cmds.submit()
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

function cmds.before() swap('LEFT') end
function cmds.after() swap('RIGHT') end
cmds.refresh = refresh

function M.command(o)
  local sub = o.fargs[1]
  if not cmds[sub] then return notify('unknown subcommand: ' .. sub, vim.log.levels.ERROR) end
  if not S and sub ~= 'open' then return notify('no review open; run :Critique open <url>', vim.log.levels.ERROR) end
  gh.async(cmds[sub])(o)
end

return M
