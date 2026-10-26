# Shell setup for the demo tapes (zsh): your nvim config plus this checkout of the plugin.
plugin=${0:A:h:h}
export CRITIQUE_DEMO=$plugin # tmux panes re-source this file, since their shells re-run your rc files
export PATH="$HOME/go/bin:$plugin/bin:$PATH"
export COLORTERM=truecolor GH_PAGER=cat
# VHS's xterm.js misdraws the colon-style RGB codes nvim sends when it thinks it is in iTerm2.
export TERM_PROGRAM=vhs
# Load the plugin from this checkout, and hide lazy.nvim's "Plugin Updates" popup while recording.
export VIMINIT="set termguicolors | source ~/.config/nvim/init.lua | set rtp^=$plugin | runtime plugin/critique.lua | lua local n = vim.notify; vim.notify = function(m, ...) if not tostring(m):find('Plugin Updates', 1, true) then return n(m, ...) end end"
