# A short clip for the README: vhs demo/clips/threads.tape  (run from the repo root; stages a local review first)
Output demo/clips/threads.gif
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
Type ":Critique threads" Sleep 400ms Enter
Sleep 3s
Type "]q"
Sleep 2.5s
Type ":Critique resolve" Sleep 400ms Enter
Wait+Screen@10s /thread resolved/
Sleep 3s
