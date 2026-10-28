#!/bin/sh
# Stages a local review for the short demo clips (demo/clips/*.tape), offline: an agent's change to a small
# Go repo, your first review of it (two comments, then a submit), and the agent's second round, which
# answers both. Usage: demo/clips-setup.sh [dir]   (default /tmp/critique-clips; the repo is <dir>/shop)
set -eu
plugin=$(cd "$(dirname "$0")/.." && pwd)
dir=${1:-/tmp/critique-clips}
critique() { "$plugin/bin/critique" "$@" >/dev/null; }
rm -rf "$dir" && mkdir -p "$dir/shop/cart" "$dir/shop/discount" && cd "$dir/shop"
git init -q -b main && git config user.name you && git config user.email you@example.com

cat > go.mod <<'EOF'
module example.com/shop

go 1.22
EOF
cat > cart/cart.go <<'EOF'
// Package cart holds the items a customer is about to buy.
package cart

import "fmt"

// Item is one line in the cart.
type Item struct {
	Name  string
	Price int // cents
	Qty   int
}

// Cart is a list of items.
type Cart struct {
	items []Item
}

// Add puts qty of an item in the cart.
func (c *Cart) Add(name string, price, qty int) {
	c.items = append(c.items, Item{Name: name, Price: price, Qty: qty})
}

// Subtotal is the sum of all items, in cents.
func (c *Cart) Subtotal() int {
	total := 0
	for _, it := range c.items {
		total += it.Price * it.Qty
	}
	return total
}

// Summary describes the cart for the checkout page.
func (c *Cart) Summary() string {
	return fmt.Sprintf("%d items, %d cents", len(c.items), c.Subtotal())
}
EOF
git add -A && git commit -qm 'Cart'

# Round 1, the agent: promo codes.
critique start --title 'Promo codes' --base HEAD --as claude
perl -0pi -e 's/import "fmt"/import (\n\t"fmt"\n\n\t"example.com\/shop\/discount"\n)/; s/\titems \[\]Item\n/\titems []Item\n\tcode  string\n/; s/(func \(c \*Cart\) Add\(name string, price, qty int\) \{\n)/$1\tqty = max(qty, 1)\n/; s/(\/\/ Summary describes)/\/\/ ApplyCode sets the promo code used by Total.\nfunc (c *Cart) ApplyCode(code string) error {\n\tif !discount.Valid(code) {\n\t\treturn fmt.Errorf("unknown promo code %q", code)\n\t}\n\tc.code = code\n\treturn nil\n}\n\n\/\/ Total is the subtotal after any promo code, in cents.\nfunc (c *Cart) Total() int {\n\treturn discount.Apply(c.code, c.Subtotal())\n}\n\n$1/; s/c\.Subtotal\(\)\)\n\}\n$/c.Total())\n}\n/' cart/cart.go
cat > discount/discount.go <<'EOF'
// Package discount applies promo codes to a subtotal.
package discount

type rule struct {
	percent int // whole percent off
	fixed   int // cents off
}

var codes = map[string]rule{
	"SAVE10":  {percent: 10},
	"FIVEOFF": {fixed: 500},
}

// Valid reports whether code is a known promo code.
func Valid(code string) bool {
	_, ok := codes[code]
	return ok
}

// Apply returns subtotal after the code's discount, never below zero.
func Apply(code string, subtotal int) int {
	r, ok := codes[code]
	if !ok {
		return subtotal
	}
	return max(subtotal*(100-r.percent)/100-r.fixed, 0)
}
EOF
critique submit --summary 'Added the SAVE10 and FIVEOFF promo codes.' --as claude

# Your first review, saved the way Neovim saves it: two comments, then a submit with a snapshot of the files.
CRITIQUE_PLUGIN=$plugin nvim --clean --headless -l /dev/stdin <<'EOF'
package.path = os.getenv('CRITIQUE_PLUGIN') .. '/lua/?.lua;' .. package.path
local store = require('critique.store')
local log = store.list(vim.uv.cwd())[1].log
local function comment(path, line, code, body)
  local id = store.new_id()
  store.append(log, { type = 'comment', id = id, thread = id, author = 'you', role = 'human', body = body,
    path = path, side = 'new', line = line, code = { code } })
end
local function line_of(path, text)
  for i, l in ipairs(vim.fn.readfile(path)) do if l == text then return i end end
end
comment('cart/cart.go', line_of('cart/cart.go', '\tqty = max(qty, 1)'), '\tqty = max(qty, 1)',
  'Clamping hides bugs in the caller. Reject qty < 1 instead?')
comment('discount/discount.go', line_of('discount/discount.go', '\t"FIVEOFF": {fixed: 500},'), '\t"FIVEOFF": {fixed: 500},',
  'FIVEOFF takes a $3 order to $0. Should it need a minimum order?')
store.append(log, { type = 'submit', author = 'you', role = 'human', summary = 'Two things before this goes in.', tree = store.snapshot(vim.uv.cwd()) })
EOF

# Round 2, the agent: it fixes both, with a test, and answers.
perl -0pi -e 's/Add\(name string, price, qty int\) \{\n\tqty = max\(qty, 1\)\n(\tc\.items = .*?\n)/Add(name string, price, qty int) error {\n\tif qty < 1 {\n\t\treturn fmt.Errorf("bad qty")\n\t}\n$1\treturn nil\n/s' cart/cart.go
perl -0pi -e 's/(\tfixed   int \/\/ cents off\n)/$1\tmin     int \/\/ smallest subtotal the code applies to, in cents\n/; s/\{fixed: 500\}/{fixed: 500, min: 1000}/; s/if !ok \{/if !ok || subtotal < r.min {/' discount/discount.go
cat > discount/discount_test.go <<'EOF'
package discount

import "testing"

func TestApply(t *testing.T) {
	for _, tc := range []struct {
		code     string
		subtotal int
		want     int
	}{
		{"SAVE10", 2000, 1800},
		{"FIVEOFF", 2000, 1500},
		{"FIVEOFF", 300, 300}, // under the minimum
	} {
		if got := Apply(tc.code, tc.subtotal); got != tc.want {
			t.Errorf("Apply(%q, %d) = %d, want %d", tc.code, tc.subtotal, got, tc.want)
		}
	}
}
EOF
critique reply 1 'Done: Add returns an error for qty < 1.' --as claude
critique reply 2 'Good catch: FIVEOFF now needs a $10 order, with a test.' --as claude
critique submit --summary 'Validated qty; FIVEOFF needs a $10 order.' --as claude
echo "$dir/shop"
