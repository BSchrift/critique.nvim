# A short clip for the README: vhs demo/clips/overview.tape  (run from the repo root; reads a sandbox PR)
Output demo/clips/overview.gif
Set Shell "zsh"
Set FontSize 16
Set Width 1280
Set Height 640
Set Padding 12
Set TypingSpeed 40ms
Set CursorBlink false
Hide
Type "source demo/env.sh && clear" Enter
Type "critique https://github.com/BSchrift/nvim-reviewer-sandbox/pull/5" Enter
Wait+Screen@60s / changed/
Sleep 1s
Type ":echo ''" Enter
Show
Sleep 1.5s
Type ":Critique overview" Sleep 400ms Enter
Wait+Screen@20s /Checks:/
Sleep 4s
Type "G"
Sleep 3s
