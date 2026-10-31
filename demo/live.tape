# Records the README's top GIF, a live review: vhs demo/live.tape  (run from the repo root)
# Needs vhs, tmux, Go, and Claude Code (logged in). Same setup as demo/agent.tape; Claude's waits are hidden.
Output demo/live.gif

Set Shell "zsh"
Set FontSize 14
Set Width 1920
Set Height 1080
Set Padding 8
Set TypingSpeed 25ms
Set CursorBlink false

Hide
Type "source demo/env.sh && cd $(demo/agent-setup.sh $(mktemp -d)) && clear" Enter
Sleep 1s
Type "tmux -L critique-demo -f $plugin/demo/tmux.conf new-session -s demo \; split-window -h \; select-pane -L" Enter
Sleep 2s
# The panes' shells re-run your rc files, which may put an installed critique first on PATH.
Type "source $CRITIQUE_DEMO/demo/env.sh && clear" Enter
Ctrl+B
Right
Type "source $CRITIQUE_DEMO/demo/env.sh && clear" Enter
Ctrl+B
Left
# Auto mode: a fix chained into one shell command would otherwise stop for a permission prompt.
Type "clear && claude --model sonnet --effort medium --permission-mode auto" Enter
Wait+Screen@60s /trust this folder/
Sleep 2s
Down
Sleep 500ms
Enter
Wait+Screen@60s /auto mode on/
Sleep 1s
Ctrl+B
Type@5ms ":set -g @caption '1/3  You ask Claude Code for a change, and a live review in critique'" Enter
Show

# --- 1. the request ---------------------------------------------------------
Sleep 1s
Type "Make the FIVEOFF promo code require a minimum order of $10, then hand it to me for a live review in critique."
Sleep 500ms
Enter
Sleep 4s
Hide
Wait+Screen@8m /critique wait/
Sleep 3s
Show
Sleep 2s

# --- 2. you comment in Neovim -----------------------------------------------
Hide
Ctrl+B
Right
Ctrl+B
Type@5ms ":set -g @caption '2/3  You open it in Neovim and comment. Each comment reaches Claude when you :w, no submit'" Enter
Show
Type "critique" Enter
Wait+Screen@30s /changed · /
Sleep 2s
Type ":Critique comment" Sleep 300ms Enter
Sleep 1s
Type "iPlease add a test for an order just under $10."
Escape
Sleep 300ms
Type ":w" Sleep 300ms Enter
Sleep 1s
Type ":q" Enter
Sleep 3s

# --- 3. Claude reacts --------------------------------------------------------
Hide
Ctrl+B
Type@5ms ":set -g @caption '3/3  Claude starts on it right away (⏳), adds the test, and replies in the thread'" Enter
Wait+Screen@2m /is on #1/
Sleep 1s
Show
Sleep 4s
Hide
Wait+Screen@8m /replied on #/
Show
Sleep 2s
Type ":Critique comment" Sleep 300ms Enter
Sleep 6s

Hide
Ctrl+B
Type ":kill-server" Enter
