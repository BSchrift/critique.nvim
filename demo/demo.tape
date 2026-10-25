# Records the README demo: vhs demo/demo.tape  (run from the repo root)
# Uses your own nvim config plus this checkout (see env.sh). Point the URL below at a PR you can review.
Output demo/demo.mp4
Output demo/demo.gif

Set Shell "zsh"
Set FontSize 15
Set Width 1600
Set Height 960
Set Padding 12
Set TypingSpeed 35ms
Set CursorBlink false

Hide
Type "source demo/env.sh && clear" Enter
Show

# --- open -------------------------------------------------------------------
Type "critique https://github.com/BSchrift/nvim-reviewer-sandbox/pull/3"
Sleep 800ms
Enter
Sleep 4.5s
Hide
Type@5ms ":command! -nargs=1 Cap echohl ModeMsg | echo <q-args> | echohl None" Enter
Type@5ms ":Cap ▶ The PR is checked out in a worktree and opened in your normal nvim. Changed files are in the quickfix list." Enter
Show
Sleep 4s

# --- diff navigation --------------------------------------------------------
Hide
Type@5ms ":Cap ▶ GitHub-style diff over the real file: green = added, red virtual lines = removed, darker = changed words. ]c / [c jump." Enter
Show
Sleep 2s
Type "]czz"
Sleep 1.8s
Type "]czz"
Sleep 1.8s
Type "]czz"
Sleep 2.2s
Type "]czz"
Sleep 2.2s
Type "]czz"
Sleep 2.5s

# --- comment ----------------------------------------------------------------
Type ":31" Enter
Type "zz"
Hide
Type@5ms ":Cap ▶ :Critique comment opens a markdown buffer. :w saves it to your pending review on GitHub." Enter
Show
Sleep 2.5s
Type ":Critique comment" Sleep 400ms Enter
Sleep 1s
Type "iNice use of the max builtin. Should a negative qty be rejected instead?"
Escape
Sleep 500ms
Type ":w" Sleep 300ms Enter
Sleep 3s
Type ":q" Enter
Sleep 2.5s

# --- multi-line comment -----------------------------------------------------
Type ":55" Enter
Type "zt"
Hide
Type@5ms ":Cap ▶ Select lines in visual mode, then :Critique comment, for a multi-line comment." Enter
Show
Sleep 2s
Type "V7j"
Sleep 800ms
Type ":Critique comment" Sleep 400ms Enter
Sleep 1s
Type "iApplyCode silently replaces a code that is already set. Intended?"
Escape
Type ":w" Sleep 300ms Enter
Sleep 3s
Type ":q" Enter
Sleep 2.5s

# --- LSP into a new file, existing thread ------------------------------------
Type ":66" Enter
Type "0fA"
Hide
Type@5ms ":Cap ▶ Your LSP works as usual: gd on discount.Apply jumps into the new file the PR adds." Enter
Show
Sleep 2.5s
Type "gd"
Sleep 3s
Type ":11" Enter
Hide
Type@5ms ":Cap ▶ Existing threads show at the end of the line. :Critique comment there to read the thread and reply." Enter
Show
Sleep 3s
Type ":Critique comment" Sleep 400ms Enter
Sleep 2.5s
Type "iGood catch. I will add a $10 minimum for FIVEOFF."
Escape
Type ":w" Sleep 300ms Enter
Sleep 3s
Type ":q" Enter
Sleep 2s
Hide
Type@5ms ":Cap ▶ :Critique resolve resolves (or unresolves) the thread on this line." Enter
Show
Sleep 2s
Type ":Critique resolve" Sleep 400ms Enter
Sleep 3s

# --- telescope + gd across the repo ----------------------------------------
Hide
Type@5ms ":Cap ▶ Telescope works across the whole repo, whether or not a file is part of the PR." Enter
Show
Sleep 2s
Type " ff"
Sleep 1s
Type "main"
Sleep 2s
Enter
Sleep 1.5s
Hide
Type@5ms ":Cap ▶ main.go is not part of the PR, so no overlay. gd on cart.New lands back in the review." Enter
Show
Sleep 2.5s
Type "/New" Enter
Sleep 800ms
Type "gd"
Sleep 3s
Type ":71" Enter
Type "0fF"
Hide
Type@5ms ":Cap ▶ gd on money.Format opens a file the PR does not touch. Ctrl-o comes back." Enter
Show
Sleep 2.5s
Type "gd"
Sleep 3s
Ctrl+O
Sleep 2s
Hide
Type@5ms ":Cap ▶ Live grep searches PR files and the rest of the repo together." Enter
Show
Sleep 2s
Type " fg"
Sleep 1s
Type "promo"
Sleep 3s
Escape
Escape
Sleep 500ms

# --- before / after / toggle ------------------------------------------------
Type ":cfirst" Enter
Type ":71" Enter
Type "zz"
Hide
Type@5ms ":Cap ▶ :Critique before shows the file as it was, at the same spot. :Critique after switches back." Enter
Show
Sleep 2.5s
Type ":Critique before" Sleep 400ms Enter
Sleep 3.5s
Type ":Critique after" Sleep 400ms Enter
Sleep 2.5s
Hide
Type@5ms ":Cap ▶ :Critique toggle hides the overlay so you see the plain file." Enter
Show
Sleep 2s
Type ":Critique toggle" Sleep 400ms Enter
Sleep 3s
Type ":Critique toggle" Sleep 400ms Enter
Sleep 2s

# --- deleted file -----------------------------------------------------------
Hide
Type@5ms ":Cap ▶ Deleted files open from the quickfix list as their old version." Enter
Show
Sleep 2s
Type ":clast" Enter
Sleep 3s
Type ":cfirst" Enter
Sleep 1s

# --- delete + submit --------------------------------------------------------
Type ":31" Enter
Type "zz"
Hide
Type@5ms ":Cap ▶ :Critique delete removes one of your comments on this line." Enter
Show
Sleep 2s
Type ":Critique delete" Sleep 400ms Enter
Sleep 1.5s
Type "1" Sleep 400ms Enter
Sleep 3s
Hide
Type@5ms ":Cap ▶ :Critique submit publishes everything at once: Comment, Approve, or Request changes." Enter
Show
Sleep 2.5s
Type ":Critique submit" Sleep 400ms Enter
Sleep 1.5s
Type "1" Sleep 400ms Enter
Sleep 800ms
Type "Looks good overall, two small questions inline."
Sleep 500ms
Enter
Sleep 3.5s
Type ":qa!" Enter
Sleep 1s

# --- proof ------------------------------------------------------------------
Type `gh api repos/BSchrift/nvim-reviewer-sandbox/pulls/3/comments --jq '.[] | "\(.path):\(.line)  \(.body)"'`
Sleep 500ms
Enter
Sleep 5s
