# Records the README's "new in 0.2" demo: vhs demo/features.tape  (run from the repo root)
# Stage a PR first with demo/features-setup.sh and put its URL below; recording submits a review on it.
# Uses your own nvim config plus this checkout (see env.sh).
Output demo/features.mp4
Output demo/features.gif

Set Shell "zsh"
Set FontSize 15
Set Width 1600
Set Height 960
Set Padding 12
Set TypingSpeed 35ms
Set CursorBlink false

Hide
Type "source demo/env.sh && clear" Enter
# Open the PR once off camera, so the recording doesn't wait on the first fetch.
Type "critique https://github.com/BSchrift/nvim-reviewer-sandbox/pull/5" Enter
Wait+Screen@30s /files changed/
Type ":qa!" Enter
Type "clear" Enter
Show

# --- open: round two ---------------------------------------------------------
Type "critique https://github.com/BSchrift/nvim-reviewer-sandbox/pull/5"
Sleep 800ms
Enter
Wait+Screen@30s /since your last review/
Sleep 3.5s
Hide
Type@5ms ":command! -nargs=1 Cap echohl ModeMsg | echo <q-args> | echohl None" Enter
Type@5ms ":Cap ▶ Back for round two. The author pushed fixes, and critique says what's new since your review." Enter
Show
Sleep 3s

# --- overview ----------------------------------------------------------------
Hide
Type@5ms ":Cap ▶ :Critique overview shows the description, CI checks, and the conversation so far." Enter
Show
Sleep 2s
Type ":Critique overview" Sleep 400ms Enter
Wait+Screen@20s /Conversation/
Sleep 5s
Type ":q" Enter
Sleep 1s

# --- since -------------------------------------------------------------------
Hide
Type@5ms ":Cap ▶ :Critique since shows only what changed since your last review." Enter
Show
Sleep 2s
Type ":Critique since" Sleep 400ms Enter
Wait+Screen@20s /changed since your last review/
Sleep 3.5s

# --- suggest by editing ------------------------------------------------------
Hide
Type "/bad qty" Enter
Type ":noh" Enter
Type@5ms ":Cap ▶ Suggest by editing: change the code and :w. Nothing is saved; you get a preview instead." Enter
Show
Sleep 3s
Type `ci"`
Sleep 300ms
Type "qty must be at least 1, got %d"
Escape
Type "f)i, qty"
Escape
Sleep 1.2s
Type ":w" Sleep 400ms Enter
Wait+Screen@10s /Suggest this change/
Sleep 4s
Type "y"
Wait+Screen@20s /saved to your pending review/
Sleep 3.5s

# --- viewed ------------------------------------------------------------------
Hide
Type@5ms ":Cap ▶ :Critique viewed ticks a file off (GitHub's Viewed box too) and goes to the next one." Enter
Show
Sleep 2.5s
Type ":Critique viewed" Sleep 400ms Enter
Sleep 3s
Type ":Critique viewed" Sleep 400ms Enter
Sleep 3.5s

# --- threads -----------------------------------------------------------------
Hide
Type@5ms ":Cap ▶ :Critique threads lists every open thread. The author fixed this one: :Critique resolve." Enter
Show
Sleep 2s
Type ":Critique threads" Sleep 400ms Enter
Sleep 3s
Type ":Critique resolve" Sleep 400ms Enter
Wait+Screen@20s /thread resolved/
Sleep 2.5s
Hide
Type@5ms ":Cap ▶ It stays in the list, marked resolved. ]q / [q step through the rest." Enter
Show
Sleep 2.5s
Type "]q"
Sleep 2.5s
Type "]q"
Sleep 3s

# --- submit ------------------------------------------------------------------
Hide
Type@5ms ":Cap ▶ :Critique submit publishes the review, suggestion included." Enter
Show
Sleep 2s
Type ":Critique submit" Sleep 400ms Enter
Sleep 1.5s
Type "1" Sleep 400ms Enter
Sleep 800ms
Type "One suggestion, otherwise good to go."
Sleep 500ms
Enter
Wait+Screen@20s /review submitted/
Sleep 2.5s
Type ":qa!" Enter
Sleep 1s

# --- proof -------------------------------------------------------------------
Type `gh api repos/BSchrift/nvim-reviewer-sandbox/pulls/5/comments --jq '.[-1] | "\(.path):\(.line)\n\(.body)"'`
Sleep 500ms
Enter
Sleep 5s
