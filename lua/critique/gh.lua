-- Coroutine helpers around vim.system, plus GitHub GraphQL through the gh CLI.
local M = {}

local finished = setmetatable({}, { __mode = 'k' }) -- coroutine -> function(ok, err), for M.all

local function step(co, ...)
  local ok, err = coroutine.resume(co, ...)
  if coroutine.status(co) == 'dead' and finished[co] then
    finished[co](ok, err)
  elseif not ok then
    vim.notify('critique: ' .. tostring(err), vim.log.levels.ERROR)
  end
end

-- Run fn in a coroutine so it can await; errors are shown instead of thrown.
function M.async(fn)
  return function(...) step(coroutine.create(fn), ...) end
end

-- Call a callback-last function from inside M.async and return what it passes to the callback.
function M.await(fn, ...)
  local co, n, args = coroutine.running(), select('#', ...), { ... }
  args[n + 1] = function(...)
    local res = { n = select('#', ...), ... }
    vim.schedule(function() step(co, unpack(res, 1, res.n)) end)
  end
  fn(unpack(args, 1, n + 1))
  return coroutine.yield()
end

-- From inside M.async: runs fns at the same time (each can await) and returns their results in order.
-- If one raises, the error is raised here once they have all finished.
function M.all(fns)
  local parent, results, left, waiting, err = coroutine.running(), {}, #fns, false, nil
  for i, fn in ipairs(fns) do
    local co = coroutine.create(function() results[i] = fn() end)
    finished[co] = function(ok, e)
      err, left = err or (not ok and e or nil), left - 1
      if left == 0 and waiting then vim.schedule(function() step(parent) end) end
    end
    step(co)
  end
  if left > 0 then
    waiting = true
    coroutine.yield()
  end
  if err then error(err, 0) end
  return unpack(results, 1, #fns)
end

function M.run(cmd, opts)
  return M.await(vim.system, cmd, opts or {})
end

-- Runs a git command that takes --progress (args, with optional stdin), passing each progress line to on_progress
-- as git redraws it. Returns whether it worked, and its stdout or (without the progress lines) its stderr.
function M.git_progress(dir, on_progress, args, stdin)
  local err = {}
  local r = M.run({ 'git', '-C', dir, unpack(args) }, { stdin = stdin, stderr = function(_, data)
    if not data then return end
    table.insert(err, data)
    local line = data:match('([^\r\n]+)[\r\n]*$') -- git redraws progress with \r: the last line is the current one
    line = line and vim.trim((line:gsub('^remote: ', ''):gsub('%s+', ' ')))
    if line and line:match('^%u[%a ]*: %d') then -- "Receiving objects: 45% (…)", not "From …" or "* branch …"
      vim.schedule(function() on_progress(line) end)
    end
  end })
  if r.code == 0 then return true, r.stdout end
  return false, vim.trim((table.concat(err):gsub('[^\r\n]*\r', '')))
end

function M.git(dir, ...)
  local r = M.run({ 'git', '-C', dir, ... })
  if r.code ~= 0 then error(vim.trim(r.stderr), 0) end
  return r.stdout
end

-- host is the GitHub host of the PR (github.com, or a GitHub Enterprise Server domain).
function M.gql(host, query, vars)
  local r = M.run({ 'gh', 'api', 'graphql', '--hostname', host, '--input', '-' }, { stdin = vim.json.encode({ query = query, variables = vars }) })
  local ok, res = pcall(vim.json.decode, r.stdout, { luanil = { object = true, array = true } })
  if not ok or not res or res.errors or r.code ~= 0 then
    error(ok and res and res.errors and res.errors[1].message or vim.trim(r.stderr), 0)
  end
  return res.data
end

-- The commit a PR's diff starts from: the merge base of its base and head (GitHub's GraphQL API doesn't have it).
function M.merge_base(host, owner, name, base, head)
  local path = ('repos/%s/%s/compare/%s...%s?per_page=1'):format(owner, name, base, head)
  local r = M.run({ 'gh', 'api', '--hostname', host, path, '--jq', '.merge_base_commit.sha' })
  if r.code ~= 0 or vim.trim(r.stdout) == '' then error(vim.trim(r.stderr ~= '' and r.stderr or 'no merge base for this PR'), 0) end
  return vim.trim(r.stdout)
end

-- Run a GitHub mutation by name; `fields` selects what to return from its payload.
function M.mutate(host, name, input, fields)
  local q = ('mutation($i: %sInput!) { %s(input: $i) { %s } }'):format(name:sub(1, 1):upper() .. name:sub(2), name, fields or 'clientMutationId')
  return M.gql(host, q, { i = input })[name]
end

return M
