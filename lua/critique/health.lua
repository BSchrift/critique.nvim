-- :checkhealth critique
local M = {}
local health = vim.health
local plugin = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')

local function run(cmd)
  local ok, r = pcall(function() return vim.system(cmd, { text = true }):wait() end)
  return ok and r or { code = -1, stdout = '', stderr = '' }
end

function M.check()
  health.start('critique.nvim')
  if vim.fn.has('nvim-0.11') == 1 then
    health.ok('Neovim ' .. tostring(vim.version()))
  else
    health.error('Neovim 0.11 or newer is needed')
  end
  local git = run({ 'git', '--version' }).stdout:match('(%d+%.%d+%.?%d*)')
  if not git then
    health.error('git not found', 'Install git.')
  elseif vim.version.lt(git, '2.31') then -- for rev-parse --path-format and fetch --stdin
    health.error(('git %s is too old: critique needs 2.31 or newer'):format(git))
  else
    health.ok('git ' .. git)
  end
  local unknown = vim.tbl_filter(function(k) return require('critique').defaults[k] == nil end, vim.tbl_keys(require('critique').config))
  table.sort(unknown)
  for _, k in ipairs(unknown) do
    health.warn(('unknown option %q in setup()'):format(k), 'Options: ' .. table.concat(vim.tbl_keys(require('critique').defaults), ', '))
  end

  health.start('GitHub pull requests')
  if vim.fn.executable('gh') == 0 then
    health.warn('the GitHub CLI (gh) is not installed: reviewing GitHub PRs needs it', 'Install it from https://cli.github.com')
  else
    local r = run({ 'gh', 'auth', 'status' })
    local hosts = {}
    for host in (r.stdout .. r.stderr):gmatch('Logged in to (%S+)') do hosts[#hosts + 1] = host end
    if #hosts > 0 then
      health.ok('gh is logged in to ' .. table.concat(hosts, ', '))
    else
      health.warn('gh is not logged in', { 'Run gh auth login', 'For GitHub Enterprise: gh auth login --hostname <host>' })
    end
  end

  health.start('Reviews with AI agents')
  local exe = vim.fn.exepath('critique')
  if exe == '' then
    health.warn('the `critique` command is not on your PATH: agents use it, and you can open reviews with it',
      ('ln -s %s/bin/critique ~/.local/bin/critique'):format(vim.fn.fnamemodify(plugin, ':~')))
  elseif vim.fn.resolve(exe) ~= plugin .. '/bin/critique' then
    health.warn(('`critique` on your PATH (%s) is another copy of the plugin, not this one'):format(vim.fn.resolve(exe)),
      ('ln -sf %s/bin/critique %s'):format(vim.fn.fnamemodify(plugin, ':~'), exe))
  else
    health.ok('`critique` command: ' .. exe)
  end
  local skills = vim.tbl_filter(function(dir) return vim.uv.fs_stat(vim.fn.expand(dir) .. '/SKILL.md') ~= nil end,
    { '~/.claude/skills/critique', '~/.agents/skills/critique' })
  if #skills > 0 then
    health.ok('agent skill: ' .. table.concat(skills, ', '))
  else
    health.info('no agent skill in ~/.claude/skills or ~/.agents/skills (or it is set up per repo). See the README to give your agent the critique skill.')
  end
end

return M
