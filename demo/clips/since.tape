# A short clip for the README: vhs demo/clips/since.tape  (run from the repo root; stages a local review first)
Output demo/clips/since.gif
Set Shell "zsh"
Set FontSize 16
Set Width 1280
Set Height 640
Set Padding 12
Set TypingSpeed 40ms
Set CursorBlink false
Hide
Type "source demo/env.sh && demo/clips-setup.sh >/dev/null && cd /tmp/critique-clips/shop && clear" Enter
Sleep 6s
Type "critique" Enter
Wait+Screen@30s /open threads/
Sleep 1s
Type ":echo ''" Enter
Show
Sleep 1.5s
Type ":Critique since" Sleep 400ms Enter
Wait+Screen@10s /changed since your last review/
Sleep 3s
Type "]c"
Sleep 2s
Type ":cnext" Enter
Sleep 3s
