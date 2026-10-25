vim.api.nvim_create_user_command('Critique', function(o) require('critique').command(o) end, {
  nargs = '+',
  range = true,
  desc = 'Review a GitHub pull request',
  complete = function(arg, line)
    if not line:match('^%S+%s+%S*$') then return {} end -- only the subcommand completes
    local names = vim.tbl_keys(require('critique').cmds)
    table.sort(names)
    return vim.tbl_filter(function(n) return vim.startswith(n, arg) end, names)
  end,
})
