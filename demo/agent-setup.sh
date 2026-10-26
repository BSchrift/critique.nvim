#!/bin/sh
# Builds the small Go shop repo that demo/agent.tape reviews: demo/agent-setup.sh <dir>  →  <dir>/shop
# It also gives Claude Code the critique skill and permission to run critique/go/git there.
set -e
plugin=$(cd "$(dirname "$0")/.." && pwd)
shop="$1/shop"
mkdir -p "$shop/cart" "$shop/discount" "$shop/money"
cd "$shop"
cat > go.mod <<'EOF'
module github.com/BSchrift/nvim-reviewer-sandbox

go 1.22
EOF
cat > main.go <<'EOF'
package main

import (
	"fmt"

	"github.com/BSchrift/nvim-reviewer-sandbox/cart"
)

func main() {
	c := cart.New()
	c.Add("coffee", 1299, 2)
	c.Add("mug", 899, 1)
	fmt.Println(c.Summary())
}
EOF
cat > cart/cart.go <<'EOF'
// Package cart holds the items a customer is about to buy.
package cart

import (
	"fmt"

	"github.com/BSchrift/nvim-reviewer-sandbox/discount"
	"github.com/BSchrift/nvim-reviewer-sandbox/money"
)

// Item is one line in the cart.
type Item struct {
	Name  string
	Price int // cents
	Qty   int
}

// Cart is a list of items and an optional promo code.
type Cart struct {
	items []Item
	code  string
}

// New returns an empty cart.
func New() *Cart {
	return &Cart{}
}

// Add puts qty of an item in the cart.
func (c *Cart) Add(name string, price, qty int) {
	qty = max(qty, 1)
	c.items = append(c.items, Item{Name: name, Price: price, Qty: qty})
}

// Remove drops the first item with this name.
func (c *Cart) Remove(name string) bool {
	for i, it := range c.items {
		if it.Name == name {
			c.items = append(c.items[:i], c.items[i+1:]...)
			return true
		}
	}
	return false
}

// Subtotal is the sum of all items, in cents.
func (c *Cart) Subtotal() int {
	total := 0
	for _, it := range c.items {
		total += it.Price * it.Qty
	}
	return total
}

// ApplyCode sets the promo code used by Total.
func (c *Cart) ApplyCode(code string) error {
	if !discount.Valid(code) {
		return fmt.Errorf("unknown promo code %q", code)
	}
	c.code = code
	return nil
}

// Total is the subtotal after any promo code, in cents.
func (c *Cart) Total() int {
	return discount.Apply(c.code, c.Subtotal())
}

// Summary describes the cart for the checkout page.
func (c *Cart) Summary() string {
	return fmt.Sprintf("%d items, %s", len(c.items), money.Format(c.Total()))
}
EOF
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
	total := subtotal*(100-r.percent)/100 - r.fixed
	return max(total, 0)
}
EOF
cat > money/money.go <<'EOF'
// Package money formats amounts stored in cents.
package money

import "fmt"

// Format renders cents as dollars, e.g. 1299 -> "$12.99".
func Format(cents int) string {
	return fmt.Sprintf("$%d.%02d", cents/100, cents%100)
}
EOF
git init -q -b main
git add -A
git -c user.name=Shop -c user.email=shop@example.com commit -qm 'Shop with promo codes'
mkdir -p .claude/skills
ln -s "$plugin/skills/critique" .claude/skills/critique
printf '.claude/\n' >> .git/info/exclude
cat > .claude/settings.local.json <<'EOF'
{
  "permissions": {
    "defaultMode": "acceptEdits",
    "allow": ["Bash(critique:*)", "Bash(critique *)", "Bash(go:*)", "Bash(gofmt:*)", "Bash(git diff:*)",
      "Bash(git status:*)", "Bash(git log:*)", "Bash(git show:*)", "Bash(cat:*)", "Bash(ls:*)", "Bash(grep:*)",
      "Bash(rg:*)", "Bash(python3:*)", "Bash(head:*)", "Bash(tail:*)", "Bash(wc:*)", "Bash(find:*)", "Bash(sed -n:*)",
      "Read", "Edit", "Write", "Glob", "Grep"]
  }
}
EOF
echo "$shop"
