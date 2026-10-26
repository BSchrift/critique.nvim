-- Coroutine helpers around vim.system, plus GitHub GraphQL through the gh CLI.
local M = {}

local function step(co, ...)
  local ok, err = coroutine.resume(co, ...)
  if not ok then vim.notify('critique: ' .. tostring(err), vim.log.levels.ERROR) end
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

function M.run(cmd, opts)
  return M.await(vim.system, cmd, opts or {})
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

-- Run a GitHub mutation by name; `fields` selects what to return from its payload.
function M.mutate(host, name, input, fields)
  local q = ('mutation($i: %sInput!) { %s(input: $i) { %s } }'):format(name:sub(1, 1):upper() .. name:sub(2), name, fields or 'clientMutationId')
  return M.gql(host, q, { i = input })[name]
end

return M
