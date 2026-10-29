-- Tiny test runner and fixtures. Every test file: `local H = dofile('tests/helpers.lua')`, then H.test(...), H.done().
-- Everything runs offline in temp git repos; gh is never called (H.forbid_gh fails the test if it is).
local H = {}
H.plugin = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
package.path = H.plugin .. '/lua/?.lua;' .. H.plugin .. '/lua/?/init.lua;' .. package.path
H.bin = H.plugin .. '/bin/critique'

-- Isolate from the user's machine: review index, git identity, git config.
H.tmp = vim.fn.tempname()
vim.fn.mkdir(H.tmp, 'p')
H.tmp = vim.uv.fs_realpath(H.tmp)
vim.env.XDG_STATE_HOME = H.tmp .. '/state'
vim.fn.writefile({ '[user]', '  name = Tester', '  email = tester@example.com', '[init]', '  defaultBranch = main' }, H.tmp .. '/gitconfig')
vim.env.GIT_CONFIG_GLOBAL, vim.env.GIT_CONFIG_NOSYSTEM = H.tmp .. '/gitconfig', '1'
vim.env.CRITIQUE_AS = nil

io.stdout:setvbuf('line') -- each result as it happens, even if the run is stopped (tests/run.sh)
local results = { passed = 0, failed = {} }
local current

-- A real prompt in headless nvim ends the run early with exit 0 and skips the rest; fail the test instead.
-- Tests that expect a prompt replace these and restore them afterwards.
local function no_prompt(what)
  return function(opts)
    error(('unexpected prompt (%s): %s'):format(what, vim.inspect(type(opts) == 'table' and opts.prompt or opts)), 0)
  end
end
vim.ui.input, vim.ui.select = no_prompt('vim.ui.input'), no_prompt('vim.ui.select')
vim.fn.input, vim.fn.confirm = no_prompt('input()'), no_prompt('confirm()')

function H.section(name)
  io.stdout:write('\n', name, '\n')
end

function H.test(name, fn)
  current = name
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    results.passed = results.passed + 1
    io.stdout:write('  ✓ ', name, '\n')
  else
    table.insert(results.failed, name)
    io.stdout:write('  ✗ ', name, '\n', '    ', (tostring(err):gsub('\n', '\n    ')), '\n')
  end
end

function H.done()
  io.stdout:write(('%d passed, %d failed\n'):format(results.passed, #results.failed))
  vim.fn.delete(H.tmp, 'rf')
  os.exit(#results.failed > 0 and 1 or 0)
end

function H.eq(got, want, what)
  if not vim.deep_equal(got, want) then
    error(('%s\n  want: %s\n  got:  %s'):format(what or 'not equal', vim.inspect(want), vim.inspect(got)), 2)
  end
end

function H.ok(cond, what)
  if not cond then error(what or 'expected a truthy value', 2) end
  return cond
end

function H.has(s, sub, what)
  if type(s) ~= 'string' or not s:find(sub, 1, true) then
    error(('%s\n  expected to find: %s\n  in: %s'):format(what or 'missing text', sub, vim.inspect(s)), 2)
  end
end

function H.lacks(s, sub, what)
  if s:find(sub, 1, true) then error(('%s\n  did not expect: %s\n  in: %s'):format(what or 'unexpected text', sub, s), 2) end
end

-- Error message of fn(...), failing if it does not error.
function H.errors(fn, ...)
  local ok, err = pcall(fn, ...)
  if ok then error('expected an error', 2) end
  return tostring(err)
end

local n = 0
function H.git(root, ...)
  local r = vim.system({ 'git', '-C', root, ... }):wait()
  if r.code ~= 0 then error(('git %s: %s'):format(table.concat({ ... }, ' '), r.stderr), 2) end
  return vim.trim(r.stdout)
end

function H.write(root, path, lines)
  vim.fn.mkdir(vim.fs.dirname(root .. '/' .. path), 'p')
  vim.fn.writefile(type(lines) == 'string' and vim.split(lines, '\n') or lines, root .. '/' .. path)
end

-- A git repo with one commit holding `files` ({ path = lines }), on branch main. Returns its real path.
function H.repo(files)
  n = n + 1
  local root = H.tmp .. '/repo' .. n
  vim.fn.mkdir(root, 'p')
  H.git(root, 'init', '-q', '-b', 'main')
  for path, lines in pairs(files or { ['README.md'] = { '# repo' } }) do H.write(root, path, lines) end
  H.git(root, 'add', '-A')
  H.git(root, 'commit', '-qm', 'base')
  return root
end

-- Runs the real `critique` launcher. Returns { code, out, err }. A hang fails the test instead of the suite.
function H.cli(cwd, args, stdin)
  local r = vim.system(vim.list_extend({ H.bin }, args), { cwd = cwd, stdin = stdin, timeout = 60000 }):wait()
  if r.signal ~= 0 then error(('critique %s was killed after hanging'):format(table.concat(args, ' ')), 2) end
  return { code = r.code, out = r.stdout, err = r.stderr }
end

-- Like H.cli, but fails unless the command succeeded.
function H.run(cwd, args, stdin)
  local r = H.cli(cwd, args, stdin)
  if r.code ~= 0 then error(('critique %s exited %d: %s%s'):format(table.concat(args, ' '), r.code, r.err, r.out), 2) end
  return r.out
end

-- The id printed by `critique start`.
function H.start(cwd, args)
  return H.run(cwd, vim.list_extend({ 'start' }, args or {})):match('Started review (%S+) ')
end

-- chmod can't take access away from root (CI containers often run as root).
function H.skip_as_root(why)
  if vim.uv.getuid() == 0 then
    io.stdout:write('    (skipped as root: ', why, ')\n')
    return true
  end
end

function H.wait_for(cond, what, ms)
  if not vim.wait(ms or 5000, cond, 20) then error('timed out waiting for ' .. (what or 'condition'), 2) end
end

-- Fail if anything tries to reach GitHub: local reviews must work 100% offline.
function H.forbid_gh()
  local system = vim.system
  vim.system = function(cmd, ...)
    if cmd[1] == 'gh' then error('local review tried to call gh: ' .. table.concat(cmd, ' '), 2) end
    return system(cmd, ...)
  end
end

return H
