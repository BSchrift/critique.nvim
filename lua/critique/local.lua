-- Local reviews with an agent: the review log (see store.lua), in the same shape as GitHub's PRs (github.lua) so
-- init.lua draws both the same way.
local gh = require('critique.gh')
local diff = require('critique.diff')
local store = require('critique.store')

local M = {}

-- What a viewed mark remembers in a local review: the file's diff, so a later change shows as "changed since viewed".
-- shortcut: binary files have no diff lines, so a change to one keeps its mark; hash the file if that matters.
local function fingerprint(f)
  local parts = { f.status, f.old_path or '' }
  for _, h in ipairs(f.hunks) do
    for _, l in ipairs(h.lines) do parts[#parts + 1] = l.kind .. l.text end
  end
  return vim.fn.sha256(table.concat(parts, '\n'))
end

-- The review, its files, threads, and viewed marks, into st (the review's state).
function M.load(st)
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
  vim.cmd.checktime() -- the agent may have changed files too
end

local function me(dir)
  local name = vim.trim(vim.fn.system({ 'git', '-C', dir, 'config', 'user.name' }))
  return name ~= '' and name or os.getenv('USER') or 'me'
end

-- A review by handle (`<id>[@path][#n]`); with no handle, the one in this repo (asking which, if several), or a new
-- one. Returns the review's state and the thread number in the handle, or nothing if you cancel.
function M.open(handle)
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
      log = store.start(root, { title = branch ~= '' and branch or nil, author = me(root), role = 'human' })
    elseif #reviews == 1 then
      log = reviews[1].log
    else
      local r = gh.await(vim.ui.select, reviews, { prompt = 'Open review', format_item = function(r) return r.id .. ' · ' .. r.title end })
      if not r then return end
      log = r.log
    end
  end
  local st = { log = log, overlay = true, backend = M }
  st.dir = vim.uv.fs_realpath(log:match('^(.*)/%.critique/reviews/'))
  st.me, st.git_dir = me(st.dir), st.dir
  M.load(st)
  return st, n
end

-- The diff since your last :Critique submit, for :Critique since.
function M.since(st)
  local from = st.review.reviewed_tree
  if not from then error('nothing to compare yet: this shows what changed after your next :Critique submit', 0) end
  return store.diff(st.review, from)
end

-- Saves a comment: an edit of ctx.comment, a reply in ctx.thread, or a new thread at ctx.anchor (on ctx.code).
-- Returns whether it reopened a resolved thread.
function M.post(st, ctx, body)
  if ctx.comment then
    store.append(st.log, { type = 'edit', id = ctx.comment.id, body = body, author = st.me, role = 'human' })
    return false
  end
  local ev = { type = 'comment', id = store.new_id(), author = st.me, role = 'human', body = body }
  ev.thread = ctx.thread and ctx.thread.id or ev.id
  if not ctx.thread then
    local a = ctx.anchor
    ev.path, ev.side, ev.line, ev.start_line, ev.code = a.path, a.side == 'LEFT' and 'old' or 'new', a.line, a.startLine, ctx.code
    if ev.side == 'new' then ev.before, ev.after = store.context(store.file_lines(st.review, ev.path, 'new') or {}, ev.code, ev.line) end
  end
  store.append(st.log, ev)
  ctx.comment = { id = ev.id }
  return ctx.thread ~= nil and ctx.thread.isResolved -- a new reply on a resolved thread
end

function M.delete(st, c)
  store.append(st.log, { type = 'delete', id = c.id, author = st.me, role = 'human' })
end

function M.resolve(st, t)
  store.append(st.log, { type = 'resolve', thread = t.id, resolved = not t.isResolved, author = st.me, role = 'human' })
end

function M.viewed(st, path, on)
  local hash = on and fingerprint(st.by_path[path]) or nil
  store.append(st.log, { type = 'viewed', path = path, viewed = on, hash = hash, author = st.me, role = 'human' })
end

-- Asks for a summary and hands the turn to the agent. Returns how many drafts that sent, or nothing if you cancel.
function M.submit(st)
  local drafts = #st.review.drafts
  local summary = gh.await(vim.ui.input, { prompt = 'Summary for the agent (optional): ' })
  if not summary then return end
  local ok, tree = pcall(store.snapshot, st.dir) -- what you reviewed, for :Critique since; never block a submit on it
  store.append(st.log, { type = 'submit', author = st.me, role = 'human', summary = summary ~= '' and summary or nil, tree = ok and tree or nil })
  return drafts
end

-- Live: comments go to the agent as you save them, instead of waiting for :Critique submit.
function M.live(st, on)
  store.append(st.log, { type = 'live', live = on, author = st.me, role = 'human' })
end

function M.status(r)
  local turn = r.closed and 'closed' or r.turn == 'human' and 'your turn' or r.turn == 'agent' and "the agent's turn" or 'not submitted yet'
  return turn .. (r.live and not r.closed and ' · live' or '')
end

-- For :Critique overview: the base and whose turn it is (as lines), and every submit's summary.
function M.overview(st)
  local r, entries = st.review, {}
  for _, ev in ipairs(store.events(st.log)) do
    if ev.type == 'submit' then table.insert(entries, { who = (ev.author or ev.role) .. ' submitted', at = ev.at, body = ev.summary or '' }) end
  end
  return { ('base `%s` (%s) · %s'):format(r.base_ref, r.base:sub(1, 7), M.status(r)) }, entries
end

return M
