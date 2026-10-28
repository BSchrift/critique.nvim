# A short clip for the README: vhs demo/clips/viewed.tape  (run from the repo root; stages a local review first)
Output demo/clips/viewed.gif
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
Type ":Critique viewed" Sleep 400ms Enter
Sleep 2.5s
Type ":Critique viewed" Sleep 400ms Enter
Sleep 2.5s
Type ":Critique viewed" Sleep 400ms Enter
Wait+Screen@10s /all 3 files viewed/
Sleep 3s
