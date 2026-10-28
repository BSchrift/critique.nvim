# A short clip for the README: vhs demo/clips/suggest.tape  (run from the repo root; stages a local review first)
Output demo/clips/suggest.gif
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
Type ":e cart/cart.go" Enter
Type "/bad qty" Enter
Type ":noh" Enter
Type "zz"
Show
Sleep 1.5s
Type `ci"`
Sleep 300ms
Type "qty must be at least 1, got %d"
Escape
Type "f)i, qty"
Escape
Sleep 1.2s
Type ":w" Sleep 400ms Enter
Wait+Screen@10s /Suggest this change/
Sleep 3s
Type "y"
Wait+Screen@10s /saved 1 suggestion/
Sleep 3s
