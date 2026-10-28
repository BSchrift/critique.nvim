-- Local reviews: an append-only JSONL event log per review, shared by the :Critique UI (role "human")
-- and the `critique` CLI that agents use (role "agent"). Appends are single writes, so both can write at once.
local M = {}

local function run(cmd, opts)
  local r = vim.system(cmd, opts or {}):wait()
  if r.code ~= 0 then error(vim.trim(r.stderr ~= '' and r.stderr or r.stdout), 0) end
  return r.stdout
end

function M.git(root, ...)
  return vim.trim(run({ 'git', '-C', root, ... }))
end

local function reviews_dir(root)
  return root .. '/.critique/reviews'
end

-- Not stdpath('state'): that depends on NVIM_APPNAME, and the human's Neovim and the agent's CLI must agree.
local function index_path()
  local state = os.getenv('XDG_STATE_HOME')
  return ((state and state ~= '') and state or (os.getenv('HOME') .. '/.local/state')) .. '/critique/index'
end

-- Lines of text without a trailing empty line, and without CR (buffers of CRLF files have none either).
local function split_lines(s)
  local lines = vim.split(s, '\n', { plain = true })
  if lines[#lines] == '' then lines[#lines] = nil end
  for i, l in ipairs(lines) do lines[i] = l:gsub('\r$', '') end
  return lines
end

local function read_lines(path)
  local f = io.open(path)
  if not f then return end
  local s = f:read('a')
  f:close()
  return split_lines(s)
end
M.read_lines = read_lines

local function rand(n)
  return (vim.uv.random(n):gsub('.', function(c) return ('%02x'):format(c:byte()) end))
end

function M.append(log, ev)
  ev.at = os.date('!%Y-%m-%dT%H:%M:%SZ')
  local line = vim.json.encode(ev) .. '\n'
  local fd = assert(vim.uv.fs_open(log, 'a', 420))
  local written, err = vim.uv.fs_write(fd, line)
  vim.uv.fs_close(fd)
  if written ~= #line then error(('could not save to %s: %s'):format(log, err or 'disk full?'), 0) end
  return ev
end

function M.new_id()
  return 'c-' .. rand(3)
end

-- Where a block of code (ending at `line`) is now, or nil if it is gone: same place, else the nearest exact match.
function M.relocate(lines, code, line)
  local n = #code
  local function at(e)
    for i = 1, n do
      if lines[e - n + i] ~= code[i] then return false end
    end
    return true
  end
  if line <= #lines and at(line) then return line end
  local best
  for e = n, #lines do
    if at(e) and (not best or math.abs(e - line) < math.abs(best - line)) then best = e end
  end
  return best
end

-- Renames between the base and the working tree, both ways. Threads always use the current path, like GitHub.
local function renames(review)
  if not review._renames then
    review._renames = { to_base = {}, to_current = {} }
    local r = vim.system({ 'git', '-C', review.root, '-c', 'diff.renames=true', 'diff', '-M', '--name-status', '-z', '--no-ext-diff', '--no-color',
      review.base }):wait()
    local parts = vim.split(r.stdout or '', '\0', { plain = true })
    local i = 1
    while i <= #parts do
      if parts[i]:match('^[RC]') then
        review._renames.to_base[parts[i + 2]], review._renames.to_current[parts[i + 1]] = parts[i + 1], parts[i + 2]
        i = i + 3
      else
        i = i + 2
      end
    end
  end
  return review._renames
end

function M.base_path(review, path) return renames(review).to_base[path] or path end
function M.current_path(review, path) return renames(review).to_current[path] or path end

-- Lines of a file in the review: the working tree for side "new", the frozen base for side "old".
function M.file_lines(review, path, side)
  if side == 'old' then
    local r = vim.system({ 'git', '-C', review.root, 'show', review.base .. ':' .. M.base_path(review, path) }):wait()
    if r.code ~= 0 then return end
    return split_lines(r.stdout)
  end
  return read_lines(review.root .. '/' .. path)
end

-- The log's events, in order, each with its line number as `seq`. A last line without its newline is a write
-- still in progress (wait and watch poll while others append), so it is left for the next read.
function M.events(log)
  local f = io.open(log) or error('no review log at ' .. log, 0)
  local text = f:read('a')
  f:close()
  local events = {}
  local lines = vim.split(text, '\n', { plain = true })
  table.remove(lines) -- after the last newline: empty, or a partial write
  for seq, line in ipairs(lines) do
    local ok, ev = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if not ok then error(('%s line %d is not valid JSON'):format(log, seq), 0) end
    ev.seq = seq
    events[seq] = ev
  end
  return events
end

-- Replays the log. `viewer` ("human" or "agent") sees its own drafts, but not the other side's until submitted.
-- Comments from the other side since the viewer's last submit are marked `new`.
-- In a live review, comments are published as they are written: there are no drafts.
function M.load(log, viewer)
  local review = { log = log, root = log:match('^(.*)/%.critique/reviews/[^/]+$'), threads = {}, closed = false, live = false, viewed = {} }
  local threads, comments, drafts, my_submit, resolves = {}, {}, {}, 0, {}
  local mine = {} -- per thread: the viewer's last comment, ack, or resolve there
  review.agent_last_seq = 0 -- the agent's last action of any kind
  for seq, ev in ipairs(M.events(log)) do
    if ev.role == 'agent' and ev.author then review.agent_author = ev.author end
    if ev.role == 'agent' and ev.type ~= 'start' then review.agent_last_seq = seq end
    if ev.role == 'human' and ev.type ~= 'viewed' then review.human_last_at = ev.at end -- viewed marks never reach the agent
    if ev.role == viewer and (ev.thread or (ev.type == 'comment' and ev.id)) then mine[ev.thread or ev.id] = seq end
    if ev.type == 'start' then
      review.id, review.title, review.base, review.base_ref, review.scope = ev.id, ev.title, ev.base, ev.base_ref, ev.scope or {}
      review.started_by, review.live = ev.role, ev.live == true
    elseif ev.type == 'live' then
      review.live = ev.live
      if ev.live then -- going live publishes everyone's drafts
        for _, c in ipairs(drafts) do c.pending = false end
      end
    elseif ev.type == 'comment' then
      local c = { id = ev.id, thread = ev.thread, author = ev.author, role = ev.role, body = ev.body, at = ev.at,
        pending = not review.live, seq = seq }
      comments[ev.id] = c
      table.insert(drafts, c)
      if threads[ev.thread] and ev.role == 'agent' then threads[ev.thread].ack = nil end -- a reply ends "on it"
      -- Answering a resolved thread ("not quite") reopens it, so the agent sees it. A draft reopens it once it is
      -- submitted (or, for its writer, right away), unless it gets deleted: the agent must not learn about drafts.
      if threads[ev.thread] and ev.role == 'human' and threads[ev.thread].resolved then
        if c.pending then c.reopens = true else threads[ev.thread].resolved = false end
      end
      -- A thread must be on a file in the checkout: not an absolute path, and not one that climbs out with "..".
      local inside = type(ev.path) == 'string' and not ev.path:match('^/') and not ('/' .. ev.path .. '/'):find('/%.%./')
      if ev.thread == ev.id and inside then
        threads[ev.id] = {
          id = ev.id, n = #review.threads + 1, path = ev.path, side = ev.side, line = ev.line,
          start_line = ev.start_line, orig_line = ev.line, code = ev.code, resolved = false, comments = {},
        }
        table.insert(review.threads, threads[ev.id])
      end
      if threads[ev.thread] then table.insert(threads[ev.thread].comments, c) end
    elseif ev.type == 'edit' and comments[ev.id] then
      comments[ev.id].body = ev.body
    elseif ev.type == 'delete' and comments[ev.id] then
      comments[ev.id].deleted = true
    elseif ev.type == 'resolve' and threads[ev.thread] then
      threads[ev.thread].resolved, threads[ev.thread].ack, threads[ev.thread].resolved_seq = ev.resolved, nil, seq
      if ev.role == viewer and not review.live then table.insert(resolves, { seq = seq, n = threads[ev.thread].n }) end
    elseif ev.type == 'ack' and threads[ev.thread] then
      threads[ev.thread].ack = { author = ev.author, seq = seq }
    elseif ev.type == 'submit' then
      for _, c in ipairs(drafts) do
        if c.role == ev.role then
          local t = threads[c.thread]
          if c.pending and c.reopens and not c.deleted and t and t.resolved and (t.resolved_seq or 0) < c.seq then t.resolved = false end
          c.pending = false
        end
      end
      ev.seq = seq -- `at` has 1-second resolution; this tells two submits apart
      review.last_submit, review.turn = ev, ev.role == 'human' and 'agent' or 'human'
      if ev.role == viewer then my_submit, review.reviewed_tree = seq, ev.tree end
    elseif ev.type == 'viewed' and ev.role == viewer then -- the viewer's own "viewed" marks: path -> fingerprint
      review.viewed[ev.path] = ev.viewed and ev.hash or nil
    elseif ev.type == 'close' then
      review.closed = true
    end
  end

  for _, c in ipairs(drafts) do -- your own unsubmitted replies reopen their threads in your own view
    local t = threads[c.thread]
    if c.pending and c.role == viewer and c.reopens and not c.deleted and t and t.resolved and (t.resolved_seq or 0) < c.seq then
      t.resolved = false
    end
  end
  local files = {}
  review.drafts = {} -- the viewer's unsubmitted comments and resolves, by thread number
  for _, r in ipairs(resolves) do
    if r.seq > my_submit then table.insert(review.drafts, r.n) end
  end
  review.threads = vim.tbl_filter(function(t)
    t.comments = vim.tbl_filter(function(c)
      -- New: from the other side, since your last submit and since you last acted in this thread.
      c.new = c.role ~= viewer and c.seq > my_submit and c.seq > (mine[t.id] or 0)
      if c.pending and c.role == viewer and not c.deleted then table.insert(review.drafts, t.n) end
      return not c.deleted and (not c.pending or c.role == viewer)
    end, t.comments)
    if t.side == 'new' then
      -- The file was renamed since the comment: follow it.
      if not vim.uv.fs_stat(review.root .. '/' .. t.path) then t.path = M.current_path(review, t.path) end
      files[t.path] = files[t.path] or M.file_lines(review, t.path, 'new') or {}
      local now = M.relocate(files[t.path], t.code, t.orig_line)
      if now and t.start_line then t.start_line = t.start_line + now - t.orig_line end
      t.line, t.outdated = now, now == nil
    end
    -- Waiting on the agent: open, the human spoke last, and the agent hasn't said it's on it since.
    local last = t.comments[#t.comments]
    t.needs_agent = last ~= nil and not t.resolved and last.role == 'human' and not (t.ack and t.ack.seq > last.seq)
    return #t.comments > 0
  end, review.threads)
  -- Live reviews have no strict turns: it's the agent's turn while something waits on it.
  if review.live and (review.turn or #review.threads > 0) then
    local unseen = review.last_submit and review.last_submit.role == 'human' and review.last_submit.seq > review.agent_last_seq
    review.turn = (unseen or vim.iter(review.threads):any(function(t) return t.needs_agent end)) and 'agent' or 'human'
  end
  return review
end

local function default_base(root)
  local ok, head = pcall(M.git, root, 'rev-parse', '--verify', 'HEAD')
  if not ok then error('this repo has no commits yet; commit something first', 0) end
  for _, ref in ipairs({ 'origin/HEAD', 'origin/main', 'origin/master', 'main', 'master' }) do
    local ok, mb = pcall(M.git, root, 'merge-base', 'HEAD', ref)
    if ok then return mb, ref end
  end
  return head, 'HEAD'
end

-- Starts a review of the checkout at `root`. Returns the log path.
function M.start(root, opts)
  local base, base_ref
  if opts.base then
    local ok, sha = pcall(M.git, root, 'rev-parse', '--verify', '--quiet', opts.base .. '^{commit}')
    if not ok or sha == '' then error(('--base %s is not a commit'):format(opts.base), 0) end
    base, base_ref = sha, opts.base
  else
    base, base_ref = default_base(root)
  end
  local function slugify(s)
    return (s:lower():gsub('[^%w]+', '-'):gsub('^%-+', ''):sub(1, 30):gsub('%-+$', ''))
  end
  local slug = slugify(opts.title or '')
  if slug == '' then slug = slugify(vim.fs.basename(root)) end
  if slug == '' then slug = 'review' end
  vim.fn.mkdir(reviews_dir(root), 'p')
  local id
  for attempt = 1, 100 do -- ids end in 4 random hex chars; never reuse an existing review's log
    id = slug .. '-' .. (attempt == 1 and rand(2) or ('%04x'):format((tonumber(rand(2), 16) + attempt) % 65536))
    if not vim.uv.fs_stat(reviews_dir(root) .. '/' .. id .. '.jsonl') then break end
  end
  local ignore = root .. '/.critique/.gitignore'
  if not vim.uv.fs_stat(ignore) then vim.fn.writefile({ '*' }, ignore) end
  local log = reviews_dir(root) .. '/' .. id .. '.jsonl'
  M.append(log, { type = 'start', id = id, title = opts.title or slug, base = base, base_ref = base_ref,
    scope = opts.scope, author = opts.author, role = opts.role, live = opts.live or nil })
  -- The index lets `critique <id>` work from any directory. Best effort: agent sandboxes may block it.
  pcall(function()
    vim.fn.mkdir(vim.fs.dirname(index_path()), 'p')
    local f = assert(io.open(index_path(), 'a'))
    f:write(id .. '\t' .. root .. '\n')
    f:close()
  end)
  return log
end

-- The handle to give a person: `<id>`, or `<id>@<root>` when the index could not be written (shell-quoted if needed).
function M.handle(review)
  for _, line in ipairs(read_lines(index_path()) or {}) do
    if line == review.id .. '\t' .. review.root then return review.id end
  end
  local h = review.id .. '@' .. review.root
  return h:match('^[%w%-%._/@]+$') and h or vim.fn.shellescape(h)
end

local function worktrees(cwd)
  local ok, out = pcall(M.git, cwd, 'worktree', 'list', '--porcelain')
  if not ok then return {} end
  local roots = {}
  for path in out:gmatch('worktree ([^\n]+)') do roots[#roots + 1] = path end
  return roots
end

-- Open reviews in this repo (all of its worktrees), or only in the checkout at `root` if given.
-- A review log that git tracks came with the repo: whoever committed it wrote its "human" comments, which could
-- tell an agent to do anything. critique's own logs are never committed (.critique/.gitignore ignores them).
local function committed(root, id)
  return vim.system({ 'git', '-C', root, 'ls-files', '--error-unmatch', '--', '.critique/reviews/' .. id .. '.jsonl' }):wait().code == 0
end

function M.list(cwd, root)
  local found = {}
  for _, wt in ipairs(root and { root } or worktrees(cwd)) do
    for name, kind in vim.uv.fs_stat(reviews_dir(wt)) and vim.fs.dir(reviews_dir(wt)) or function() end do
      if kind == 'file' and name:match('%.jsonl$') and not committed(wt, name:sub(1, -7)) then
        local ok, review = pcall(M.load, reviews_dir(wt) .. '/' .. name, 'human')
        if ok and not review.closed then found[#found + 1] = review end
      end
    end
  end
  return found
end

-- Resolves a handle: `<id>`, `<id>@<path>`, either with `#<thread>`. Returns the log path and thread number.
function M.find(handle, cwd)
  local id, at, n = handle:match('^([^@#]+)@?([^#]*)#?(%d*)$')
  if not id then error('not a review handle: ' .. handle, 0) end
  n = tonumber(n)
  local roots = {}
  if at ~= '' then
    roots = { M.git(at, 'rev-parse', '--show-toplevel') }
  else
    for _, line in ipairs(read_lines(index_path()) or {}) do
      local i, root = line:match('^([^\t]+)\t(.+)$')
      if i == id then table.insert(roots, 1, root) end
    end
    vim.list_extend(roots, worktrees(cwd))
  end
  for _, root in ipairs(roots) do
    local log = reviews_dir(root) .. '/' .. id .. '.jsonl'
    if vim.uv.fs_stat(log) then
      if committed(root, id) then
        error(('review %s is committed to this repo, so someone else wrote it; critique only opens reviews made here'):format(id), 0)
      end
      return log, n
    end
  end
  error(('no review %s here; run `critique ls` in its repo, or use %s@<path>'):format(id, id), 0)
end

-- The working tree as a git tree, untracked files included, without touching the real index.
-- shortcut: nothing references the tree, so `git gc` may prune it after ~2 weeks; pin it with a ref if reviews last longer.
function M.snapshot(root)
  local tmp = os.tmpname()
  os.remove(tmp) -- git reads a missing index as empty, but an empty file as corrupt
  vim.uv.fs_copyfile(M.git(root, 'rev-parse', '--path-format=absolute', '--git-path', 'index'), tmp) -- lets git skip unchanged files
  local opts = { env = { GIT_INDEX_FILE = tmp } }
  local ok, tree = pcall(function()
    run({ 'git', '-C', root, 'add', '-A' }, opts)
    return vim.trim(run({ 'git', '-C', root, 'write-tree' }, opts))
  end)
  os.remove(tmp)
  if not ok then error(tree, 0) end
  return tree
end

-- Diff of the base against the working tree, with GitHub's settings. Untracked files count as added.
-- With `since` (a tree from M.snapshot), the changes from that tree to the working tree instead.
function M.diff(review, since)
  local scope = review.scope or {}
  if since then
    return run(vim.list_extend({ 'git', '-C', review.root, unpack(require('critique.diff').GIT_ARGS) },
      vim.list_extend({ since, M.snapshot(review.root), '--' }, scope)))
  end
  local out = run(vim.list_extend({ 'git', '-C', review.root, unpack(require('critique.diff').GIT_ARGS) },
    vim.list_extend({ review.base, '--' }, scope)))
  local untracked = run(vim.list_extend({ 'git', '-C', review.root, 'ls-files', '-z', '--others', '--exclude-standard', '--' }, scope))
  for _, f in ipairs(vim.split(untracked, '\0', { trimempty = true })) do
    -- --no-index exits 1 when the files differ, which they always do here; more than 1 is a real failure.
    local r = vim.system(vim.list_extend({ 'git', unpack(require('critique.diff').GIT_ARGS) }, { '--no-index', '/dev/null', f }),
      { cwd = review.root }):wait()
    if r.code > 1 then error(('git diff %s: %s'):format(f, vim.trim(r.stderr)), 0) end
    out = out .. r.stdout
  end
  return out
end

return M
