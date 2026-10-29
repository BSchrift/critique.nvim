# Records the agent demo for the README: vhs demo/agent.tape  (run from the repo root)
# Needs vhs, tmux, Go, and Claude Code (logged in). Builds a throwaway repo with demo/agent-setup.sh, then runs
# Claude Code (left) and you in Neovim (right). Claude's long thinking stretches are hidden to keep it short.
Output demo/agent.mp4
Output demo/agent.gif

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
Type "clear && claude --model sonnet --effort medium" Enter
Wait+Screen@60s /trust this folder/
Sleep 2s
Down
Sleep 500ms
Enter
Wait+Screen@60s /accept edits on/
Sleep 1s
Ctrl+B
Type@5ms ":set -g @caption '1/6  You ask Claude Code for a change, and to hand it to you for review in critique'" Enter
Show

# --- 1. the request ---------------------------------------------------------
Sleep 1s
Type "Make the FIVEOFF promo code require a minimum order of $10. Hand it to me for review with critique and iterate on my comments until I approve."
Sleep 1s
Enter
Sleep 10s
Hide
Ctrl+B
Type@5ms ":set -g @caption '2/6  Claude starts a review, makes the change, submits it, and waits for you'" Enter
Show
Sleep 8s
Hide
Wait+Screen@8m /critique wait/
Sleep 3s
Show
Sleep 5s

# --- 2. you review in Neovim ------------------------------------------------
Hide
Ctrl+B
Right
Ctrl+B
Type@5ms `:set -g @caption "3/6  You run critique: Neovim opens Claude's changes, GitHub-style, with your LSP and plugins"` Enter
Show
Type "critique" Enter
Wait+Screen@30s /changed · /
Sleep 4s
Hide
Ctrl+B
Type@5ms ":set -g @caption '4/6  Comment on any line, then :Critique submit hands the turn back to Claude'" Enter
Show
Sleep 1s
Type ":Critique comment" Sleep 300ms Enter
Sleep 1.5s
Type "iShould the minimum be checked before or after other discounts? Please add a test for an order just under $10."
Escape
Sleep 500ms
Type ":w" Sleep 300ms Enter
Sleep 2s
Type ":q" Enter
Sleep 2s
Type ":Critique submit" Sleep 300ms Enter
Sleep 1s
Type "One question, and a test please"
Sleep 500ms
Enter
Wait+Screen@20s /turn/
Sleep 3s

# --- 3. Claude addresses it ---------------------------------------------------
Hide
Ctrl+B
Left
Ctrl+B
Type@5ms ":set -g @caption '5/6  Claude gets your comments, answers, adds the test, and submits again'" Enter
Show
Sleep 12s
Hide
Wait+Screen@8m /ubmitted( ·|:)/
Sleep 2s
Show
Sleep 4s

# --- 4. you see the result and approve --------------------------------------
Hide
Ctrl+B
Right
Ctrl+B
Type@5ms `:set -g @caption "6/6  Neovim refreshes with the new code and Claude's reply. You approve; Claude closes the review"` Enter
Show
Sleep 2s
Type ":cfirst" Enter
Sleep 1.5s
Type ":Critique comment" Sleep 300ms Enter
Sleep 5s
Type ":q" Enter
Sleep 1.5s
Type ":Critique submit" Sleep 300ms Enter
Sleep 1s
Type "Approved, thanks. Please close the review."
Sleep 500ms
Enter
Sleep 2s
Hide
Ctrl+B
Left
Show
Sleep 8s
Hide
Wait+Screen@8m /closed the review/
Sleep 4s
Show
Sleep 6s

Hide
Ctrl+B
Type ":kill-server" Enter
