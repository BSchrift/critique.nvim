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
  local fd = assert(vim.uv.fs_open(log, 'a+', 420))
  -- After a write that was cut short, start a fresh line, so this event isn't lost with it.
  local size = vim.uv.fs_fstat(fd).size
  if size > 0 and vim.uv.fs_read(fd, 1, size - 1) ~= '\n' then line = '\n' .. line end
  local written, err = vim.uv.fs_write(fd, line)
  vim.uv.fs_close(fd)
  if written ~= #line then error(('could not save to %s: %s'):format(log, err or 'disk full?'), 0) end
  return ev
end

-- 40 random bits: two comments in a review sharing an id would edit or delete each other. (Logs from before
-- this have 24-bit ids, which still work: an id is only ever compared whole.)
function M.new_id()
  return 'c-' .. rand(5)
end

-- The lines just above and below a block of code (ending at `last`), saved with a thread so that relocate can
-- tell copies of the block apart. Nothing if `lines` doesn't have the block there.
function M.context(lines, code, last)
  local first = last - #code + 1
  if not vim.deep_equal(vim.list_slice(lines, first, last), code) then return end
  return vim.list_slice(lines, first - 2, first - 1), vim.list_slice(lines, last + 1, last + 2)
end

-- Where a block of code (ending at `line`) is now, or nil if it is gone. The nearest copy whose surrounding lines
-- (`before`, `after`, from M.context) still match; else the same place; else the only copy. With several copies
-- and none of that to go on, nil: better outdated than on the wrong line. (Without context: the nearest copy.)
function M.relocate(lines, code, line, before, after)
  local n = #code
  local function at(e)
    for i = 1, n do
      if lines[e - n + i] ~= code[i] then return false end
    end
    return true
  end
  local function fits(e)
    for i, l in ipairs(before or {}) do
      if lines[e - n - #before + i] ~= l then return false end
    end
    for i, l in ipairs(after or {}) do
      if lines[e + i] ~= l then return false end
    end
    return true
  end
  local function nearer(e, than) return not than or math.abs(e - line) < math.abs(than - line) end
  local best, only, copies = nil, nil, 0
  for e = n, #lines do
    if at(e) then
      copies, only = copies + 1, e
      if fits(e) and nearer(e, best) then best = e end
    end
  end
  if best then return best end
  if line <= #lines and at(line) then return line end
  return copies == 1 and only or nil
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
    -- A write cut short (a full disk, a crash) is lost, but must not take the rest of the review with it.
    if not ok or type(ev) ~= 'table' then ev = { type = 'unreadable' } end
    ev.seq = seq
    events[seq] = ev
  end
  return events
end

-- How far the agent has read a thread: to its last ack there, or, if it never acked, its last reply or resolve.
-- After an ack, its replies answer what it read then, not what the human added since; only another ack moves it.
local function saw(t, seq, ack)
  if ack or not t.seen_by_ack then t.seen_seq, t.seen_by_ack = seq, ack end
end

-- The human's comments in a loaded thread that the agent hasn't read yet: written or edited since it last did.
function M.unread(t)
  return vim.tbl_filter(function(c)
    return c.role == 'human' and math.max(c.seq, c.edited_seq or 0) > (t.seen_seq or 0)
  end, t.comments)
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
      if threads[ev.thread] and ev.role == 'agent' then -- a reply ends "on it"
        saw(threads[ev.thread], seq, false)
        threads[ev.thread].ack = nil
      end
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
          start_line = ev.start_line, orig_line = ev.line, code = ev.code, before = ev.before, after = ev.after,
          resolved = false, comments = {},
        }
        table.insert(review.threads, threads[ev.id])
      end
      if threads[ev.thread] then table.insert(threads[ev.thread].comments, c) end
    elseif ev.type == 'edit' and comments[ev.id] then
      comments[ev.id].body, comments[ev.id].edited_seq = ev.body, seq
    elseif ev.type == 'delete' and comments[ev.id] then
      comments[ev.id].deleted = true
    elseif ev.type == 'resolve' and threads[ev.thread] then
      local t = threads[ev.thread]
      if ev.role == 'agent' then saw(t, seq, false) elseif not ev.resolved then t.reopened_seq = seq end
      t.resolved, t.ack, t.resolved_seq = ev.resolved, nil, seq
      if ev.role == viewer and not review.live then table.insert(resolves, { seq = seq, n = t.n }) end
    elseif ev.type == 'ack' and threads[ev.thread] then
      threads[ev.thread].ack = { author = ev.author, seq = seq }
      saw(threads[ev.thread], seq, true)
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

  if not review.base then error(log .. ' has no readable start line, so it is not a review', 0) end
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
      local now = M.relocate(files[t.path], t.code, t.orig_line, t.before, t.after)
      if now and t.start_line then t.start_line = t.start_line + now - t.orig_line end
      t.line, t.outdated = now, now == nil
    end
    -- Waiting on the agent: open, and the human wrote, edited, or reopened something since the agent last read it.
    t.needs_agent = not t.resolved and (#M.unread(t) > 0 or (t.reopened_seq or 0) > (t.seen_seq or 0))
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

-- A review log that git tracks came with the repo: whoever committed it wrote its "human" comments, which could
-- tell an agent to do anything. critique's own logs are never committed (.critique/.gitignore ignores them).
-- Any capitalisation counts (macOS and Windows ignore case), and so does a symlinked folder, which can lead to
-- tracked files anywhere. Returns a check by review id, for the checkout at `root`.
local function committed(root)
  for _, dir in ipairs({ '/.critique', '/.critique/reviews' }) do
    if (vim.uv.fs_lstat(root .. dir) or {}).type == 'link' then return function() return true end end
  end
  local tracked = {}
  local r = vim.system({ 'git', '-C', root, 'ls-files', '-z', '--', ':(icase).critique/reviews' }):wait()
  for _, path in ipairs(vim.split(r.stdout or '', '\0', { trimempty = true })) do tracked[path:lower()] = true end
  return function(id) return tracked[('.critique/reviews/' .. id .. '.jsonl'):lower()] == true end
end

-- Whether a log has a close event, without loading it (which reads every commented file, and may run git).
-- JSON escapes quotes inside strings, so this text only appears as the event's own type.
local function closed(log)
  local f = io.open(log)
  if not f then return false end
  local text = f:read('a')
  f:close()
  return text:find('"type":"close"', 1, true) ~= nil
end

-- Open reviews in this repo (all of its worktrees), or only in the checkout at `root` if given.
function M.list(cwd, root)
  local found = {}
  for _, wt in ipairs(root and { root } or worktrees(cwd)) do
    local is_committed = committed(wt)
    for name, kind in vim.uv.fs_stat(reviews_dir(wt)) and vim.fs.dir(reviews_dir(wt)) or function() end do
      local log = reviews_dir(wt) .. '/' .. name
      if kind == 'file' and name:match('%.jsonl$') and not is_committed(name:sub(1, -7)) and not closed(log) then
        local ok, review = pcall(M.load, log, 'human')
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
      if committed(root)(id) then
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
  if untracked == '' then return out end
  -- All untracked files in one diff: an index holding only them, as "intent to add", against the working tree.
  local tmp = os.tmpname()
  os.remove(tmp) -- git reads a missing index as empty, but an empty file as corrupt
  local env = { GIT_INDEX_FILE = tmp, GIT_LITERAL_PATHSPECS = '1' } -- file names are names, not patterns
  local ok, added = pcall(function()
    run({ 'git', '-C', review.root, 'add', '--intent-to-add', '--pathspec-from-file=-', '--pathspec-file-nul' }, { env = env, stdin = untracked })
    return run({ 'git', '-C', review.root, unpack(require('critique.diff').GIT_ARGS) }, { env = env })
  end)
  os.remove(tmp)
  if not ok then error(added, 0) end
  return out .. added
end

return M
