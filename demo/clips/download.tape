# A short clip for the README: vhs demo/clips/download.tape  (run from the repo root; opens a neovim/neovim PR
# from an empty cache, so it shows the whole download)
Output demo/clips/download.gif
Set Shell "zsh"
Set FontSize 16
Set Width 1280
Set Height 640
Set Padding 12
Set TypingSpeed 35ms
Set CursorBlink false
Hide
Type "source demo/env.sh && export XDG_CACHE_HOME=$(mktemp -d) && clear" Enter
Show
Type "critique https://github.com/neovim/neovim/pull/42582"
Sleep 600ms
Enter
Wait+Screen@90s / changed/
Sleep 3s
