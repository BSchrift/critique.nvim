-- The `critique` CLI for local reviews, used by agents (and scripts). Run as: nvim -l cli.lua <command> [args]
local plugin = vim.fn.fnamemodify(_G.arg[0], ':p:h:h:h')
package.path = plugin .. '/lua/?.lua;' .. plugin .. '/lua/?/init.lua;' .. package.path
local store = require('critique.store')

local USAGE = [[
Local reviews: you and an agent review code through comment threads, stored in the repo
(.critique/), never on GitHub. The agent uses these commands; the human uses Neovim.

  critique start [--title T] [--base REF] [--scope PATH]...   start a review of this checkout
  critique ls                                     open reviews in this repo
  critique status                                 whose turn it is, thread counts
  critique list [--open] [--json]                 threads with code and comments
  critique show <n> [--json]                      one thread, with more code
  critique diff                                   the changes under review (base vs working tree)
  critique comment <path>:<line>[-<end>] [--old] <text|->   start a thread (--old: base version)
  critique reply <n> <text|->                     reply to a thread
  critique resolve <n>   /   critique unresolve <n>
  critique edit <comment-id> <text|->   /   critique delete <comment-id>
  critique submit [--summary T]                   end your turn; prints the handle for the human
  critique wait [--timeout SECONDS]               block until the human submits (exit 2 on timeout)
  critique close                                  end the review

Options: -r <id> picks the review (needed when a checkout has several), --as <name> sets
your author name (it sticks for later commands). Quote text with single quotes, or pass "-"
to read it from stdin (a <<'EOF' heredoc), so the shell can't expand backticks or $.]]

local cwd = vim.uv.cwd()
local function out(s) io.stdout:write(s, '\n') end

local VALUE = { ['-r'] = 'review', ['--review'] = 'review', ['--as'] = 'as', ['--title'] = 'title', ['--base'] = 'base',
  ['--summary'] = 'summary', ['--timeout'] = 'timeout', ['--scope'] = 'scope' }
local SWITCH = { ['--old'] = 'old', ['--open'] = 'open', ['--json'] = 'json' }
-- Positional arguments each command takes (after its name).
local ARITY = { start = 0, ls = 0, status = 0, list = 0, show = 1, diff = 0, comment = 2, reply = 2, resolve = 1,
  unresolve = 1, edit = 2, delete = 1, submit = 0, wait = 0, close = 0 }

-- Options may come before or after the command, as `--opt value` or `--opt=value`. `--` ends them, and an
-- argument with spaces in it is always text.
local function parse(argv)
  local o, i = { pos = {}, scope = {} }, 1
  while i <= #argv do
    local a, v = argv[i], nil
    if a:match('^%-%-%w[%w-]*=') then a, v = a:match('^([^=]+)=(.*)$') end
    if a == '--' then
      vim.list_extend(o.pos, argv, i + 1)
      break
    elseif a:match('%s') then
      table.insert(o.pos, a)
    elseif VALUE[a] then
      if not v then
        i = i + 1
        v = argv[i] or error(a .. ' needs a value', 0)
      end
      if VALUE[a] == 'scope' then table.insert(o.scope, v) else o[VALUE[a]] = v end
    elseif SWITCH[a] and not v then
      o[SWITCH[a]] = true
    elseif a:match('^%-%-?%a') then
      error(('unknown option %s (see critique -h)'):format(a), 0)
    else
      table.insert(o.pos, a)
    end
    i = i + 1
  end
  o.cmd = table.remove(o.pos, 1)
  return o
end

local function toplevel()
  local ok, root = pcall(store.git, cwd, 'rev-parse', '--show-toplevel')
  return ok and root or error('not inside a git repository', 0)
end

-- Explicit --as, then $CRITIQUE_AS, then whoever last wrote as the agent in this review, then "agent".
local function author(o, r)
  return o.as or os.getenv('CRITIQUE_AS') or (r and r.agent_author) or 'agent'
end

local function review_log(o)
  if o.review then return (store.find(o.review, cwd)) end
  local here = store.list(cwd, toplevel())
  if #here == 1 then return here[1].log end
  if #here == 0 then error("no open review in this checkout; start one with: critique start --title '<title>'", 0) end
  error('several open reviews here, pass -r <id>: ' .. table.concat(vim.tbl_map(function(r) return r.id end, here), ', '), 0)
end

-- The review, for commands that change it: refuses closed reviews.
local function open_review(o)
  local log = review_log(o)
  local r = store.load(log, 'agent')
  if r.closed then error(('review %s is closed'):format(r.id), 0) end
  return r, log
end

local function text(o, i)
  local t = o.pos[i] or error('missing text', 0)
  if t == '-' then t = io.read('a') end
  t = vim.trim(t)
  return t ~= '' and t or error('text is empty', 0)
end

local function thread(review, n)
  n = tonumber((n or ''):match('^#?(%d+)$')) or error('expected a thread number, e.g. 3', 0)
  for _, t in ipairs(review.threads) do
    if t.n == n then return t end
  end
  error(('no thread #%d in %s'):format(n, review.id), 0)
end

local function who(c)
  return c.author == c.role and c.author or ('%s (%s)'):format(c.author, c.role)
end

local function header(r)
  local open, resolved = 0, 0
  for _, t in ipairs(r.threads) do
    if t.resolved then resolved = resolved + 1 else open = open + 1 end
  end
  local turn = r.closed and 'closed' or r.turn and ("the %s's turn"):format(r.turn) or 'not submitted yet'
  local s = ('%s · "%s" · base %s (%s) · %s\n  checkout: %s'):format(r.id, r.title, r.base:sub(1, 7), r.base_ref, turn, r.root)
  if #r.scope > 0 then s = s .. '\n  scope: ' .. table.concat(r.scope, ' ') end
  s = s .. ('\n  threads: %d open, %d resolved'):format(open, resolved)
  local last = r.last_submit
  if last then s = s .. ('\n  last submit: %s%s'):format(last.author, last.summary and (': ' .. last.summary) or ' (no summary)') end
  return s
end

local function format_thread(r, t, context)
  local last = t.comments[#t.comments]
  local status = t.resolved and 'resolved' or t.outdated and 'outdated' or 'open'
  if not t.resolved and last.role ~= 'agent' then status = status .. ' · needs your reply' end
  local where = t.outdated and ('%s (was line %d; that code changed)'):format(t.path, t.orig_line)
    or ('%s:%s%d%s'):format(t.path, t.start_line and (t.start_line .. '-') or '', t.line, t.side == 'old' and ' (base version)' or '')
  local lines = { ('#%d %s · %s'):format(t.n, status, where) }
  if t.outdated then
    for _, c in ipairs(t.code) do table.insert(lines, '  >      | ' .. c) end
  else
    local file, first = store.file_lines(r, t.path, t.side) or {}, t.start_line or t.line
    for l = math.max(1, first - context), math.min(#file, t.line + context) do
      table.insert(lines, ('  %s %5d | %s'):format((l >= first and l <= t.line) and '>' or ' ', l, file[l]))
    end
  end
  for _, c in ipairs(t.comments) do
    local tags = (c.pending and ', draft' or '') .. (c.new and ', new' or '')
    table.insert(lines, ('  %s [%s%s]: %s'):format(who(c), c.id, tags, (c.body:gsub('\n', '\n      '))))
  end
  return table.concat(lines, '\n')
end

local function print_threads(r, o, context)
  local shown = vim.tbl_filter(function(t) return not (o.open and t.resolved) end, r.threads)
  if o.json then return out(vim.json.encode(vim.tbl_extend('force', r, { threads = shown }))) end
  out(header(r))
  for _, t in ipairs(shown) do out('\n' .. format_thread(r, t, context)) end
end

-- Paths are relative to the checkout root; paths relative to the current directory work too. Never outside it.
local function repo_path(root, path)
  local outside = path .. ' is outside the checkout'
  local real_root = vim.uv.fs_realpath(root)
  local function inside(real)
    if real:sub(1, #real_root + 1) == real_root .. '/' then return real:sub(#real_root + 2) end
    error(outside, 0)
  end
  local abs = vim.uv.fs_realpath(vim.fn.fnamemodify(path, ':p'))
  if abs then return inside(abs) end
  if path:match('^/') then -- an absolute path that isn't on disk (a deleted file): resolve its nearest existing parent
    local dir, rest = vim.fs.normalize(path), ''
    while not vim.uv.fs_realpath(dir) and dir ~= '/' do
      rest, dir = '/' .. vim.fs.basename(dir) .. rest, vim.fs.dirname(dir)
    end
    return inside(vim.uv.fs_realpath(dir) .. rest)
  end
  -- A relative path that isn't on disk is relative to the root, and still may not climb out.
  for part in path:gmatch('[^/]+') do
    if part == '..' then error(outside, 0) end
  end
  return (path:gsub('^%./', ''))
end

local function own_comment(r, id)
  for _, t in ipairs(r.threads) do
    for _, c in ipairs(t.comments) do
      if c.id == id then return c.role == 'agent' and c or error('you can only change your own comments', 0) end
    end
  end
  error(('no comment %s; edit and delete take a comment id like c-a35698 (shown in critique list)'):format(id), 0)
end

local C = {}

function C.start(o)
  local root = toplevel()
  local others = store.list(cwd, root)
  local log = store.start(root, {
    title = o.title, base = o.base, scope = #o.scope > 0 and o.scope or nil, author = author(o), role = 'agent',
  })
  local r = store.load(log, 'agent')
  out(('Started review %s (base %s, %s).'):format(r.id, r.base:sub(1, 7), r.base_ref))
  out(('Pass -r %s to every critique command for this review.'):format(r.id))
  if #others > 0 then
    out(('Note: also open in this checkout: %s.'):format(table.concat(vim.tbl_map(function(x) return x.id end, others), ', ')))
  end
  out(("Next: make your changes (or, to review the human's changes, read critique diff -r %s and comment), then critique submit -r %s --summary '...'")
    :format(r.id, r.id))
end

function C.ls()
  toplevel()
  local reviews = store.list(cwd)
  if #reviews == 0 then return out('No open reviews in this repo.') end
  for _, r in ipairs(reviews) do out(header(r) .. '\n') end
end

function C.status(o) out(header(store.load(review_log(o), 'agent'))) end
function C.list(o) print_threads(store.load(review_log(o), 'agent'), o, 2) end
function C.diff(o) io.stdout:write(store.diff(store.load(review_log(o), 'agent'))) end

function C.show(o)
  local r = store.load(review_log(o), 'agent')
  local t = thread(r, o.pos[1])
  out(o.json and vim.json.encode(t) or format_thread(r, t, 8))
end

function C.comment(o)
  local spec = o.pos[1] or error("usage: critique comment <path>:<line>[-<end>] '<text>'", 0)
  local path, l1, l2 = spec:match('^(.+):(%d+)%-?(%d*)$')
  if not path then error('expected <path>:<line> or <path>:<start>-<end>, got ' .. spec, 0) end
  local r, log = open_review(o)
  path = repo_path(r.root, path)
  local side = o.old and 'old' or 'new'
  if side == 'old' then path = store.current_path(r, path) end -- threads use the current path, even on a renamed file
  local lines = store.file_lines(r, path, side)
    or error(('%s does not exist in the %s version'):format(path, side == 'old' and 'base' or 'current'), 0)
  l1, l2 = tonumber(l1), tonumber(l2 ~= '' and l2 or l1)
  if l1 < 1 or l2 < l1 or l2 > #lines then error(('lines %d-%d are outside %s (1-%d)'):format(l1, l2, path, #lines), 0) end
  local id = store.new_id()
  store.append(log, { type = 'comment', id = id, thread = id, author = author(o, r), role = 'agent', path = path, side = side,
    line = l2, start_line = l1 < l2 and l1 or nil, code = vim.list_slice(lines, l1, l2), body = text(o, 2) })
  for _, t in ipairs(store.load(log, 'agent').threads) do
    if t.id == id then out(('Created #%d on %s:%s.'):format(t.n, path, l1 < l2 and (l1 .. '-' .. l2) or l1)) end
  end
end

function C.reply(o)
  local r, log = open_review(o)
  local t = thread(r, o.pos[1])
  store.append(log, { type = 'comment', id = store.new_id(), thread = t.id, author = author(o, r), role = 'agent', body = text(o, 2) })
  out(('Replied on #%d.'):format(t.n))
end

local function set_resolved(o, resolved)
  local r, log = open_review(o)
  local t = thread(r, o.pos[1])
  store.append(log, { type = 'resolve', thread = t.id, resolved = resolved, author = author(o, r), role = 'agent' })
  out(('%s #%d.'):format(resolved and 'Resolved' or 'Reopened', t.n))
end
function C.resolve(o) set_resolved(o, true) end
function C.unresolve(o) set_resolved(o, false) end

function C.edit(o)
  local r, log = open_review(o)
  local c = own_comment(r, o.pos[1])
  store.append(log, { type = 'edit', id = c.id, body = text(o, 2) })
  out('Edited ' .. c.id .. '.')
end

function C.delete(o)
  local r, log = open_review(o)
  local c = own_comment(r, o.pos[1])
  store.append(log, { type = 'delete', id = c.id })
  out('Deleted ' .. c.id .. '.')
end

function C.submit(o)
  local r, log = open_review(o)
  store.append(log, { type = 'submit', author = author(o, r), role = 'agent', summary = o.summary })
  out('Submitted. The human can review it with:\n  critique ' .. store.handle(store.load(log, 'agent')))
  out(('Next: critique wait -r %s'):format(r.id))
end

function C.wait(o)
  local log = review_log(o)
  local r = store.load(log, 'agent')
  if r.closed then return out('The review was closed.') end
  if #r.drafts > 0 then
    error(("you have %d unsubmitted change(s) (on #%s), and the human can't see them yet. Run: critique submit -r %s --summary '...'")
      :format(#r.drafts, table.concat(vim.fn.uniq(r.drafts), ', #'), r.id), 0)
  end
  if r.started_by == 'agent' and not r.last_submit then
    error(('nothing has been submitted yet, so the human has nothing to review. Run critique submit -r %s first.'):format(r.id), 0)
  end
  local deadline = vim.uv.now() + (tonumber(o.timeout) or 540) * 1000
  while true do
    r = store.load(log, 'agent')
    if r.closed then return out('The review was closed.') end
    if r.turn == 'agent' then
      print_threads(r, { open = true, json = o.json }, 2)
      if o.json then return end
      local open = #vim.tbl_filter(function(t) return not t.resolved end, r.threads)
      return out('\n' .. (open > 0
        and ("Next: address each thread above (change the code, reply, or resolve), then critique submit -r %s --summary '...'")
          :format(r.id)
        or ('No open threads. If the summary says the review is done, run critique close -r %s.'):format(r.id)))
    end
    if vim.uv.now() > deadline then
      out(("The human hasn't submitted yet. Run critique wait -r %s again."):format(r.id))
      os.exit(2)
    end
    vim.uv.sleep(1000)
    vim.uv.update_time()
  end
end

function C.close(o)
  local r, log = open_review(o)
  store.append(log, { type = 'close', author = author(o, r), role = 'agent' })
  out('Closed.')
end

local argv = vim.list_slice(_G.arg, 1)
if #argv == 0 or argv[1] == '-h' or argv[1] == '--help' or argv[1] == 'help' then return out(USAGE) end
local ok, err = pcall(function()
  local o = parse(argv)
  if not o.cmd then error('missing command (see critique -h)', 0) end
  if not C[o.cmd] then
    if (o.cmd or ''):match('^https?://') then
      error('critique <pull-request-url> opens the PR in Neovim, for the human; it has no shell commands', 0)
    elseif (o.cmd or ''):match('^[%w%-]+%-%x%x%x%x') then
      error(('critique %s opens the review in Neovim, for the human. From a shell, use: critique status -r %s')
        :format(o.cmd, o.cmd:match('^[^#]+')), 0)
    end
    error(('unknown command: %s (see critique -h)'):format(tostring(o.cmd)), 0)
  end
  if #o.pos > ARITY[o.cmd] then
    error(("too many arguments for critique %s: quote the text with single quotes, or pass - and a heredoc"):format(o.cmd), 0)
  end
  C[o.cmd](o)
end)
if not ok then
  io.stderr:write('critique: ', tostring(err), '\n')
  os.exit(1)
end
