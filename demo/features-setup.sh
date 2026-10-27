#!/bin/sh
# Stages a sandbox PR for demo/features.tape, a second-round review: your first review on the original
# commit, then the author's follow-up commit and comment, with passing CI. Prints the new PR's URL; each
# run makes a fresh PR, since recording the demo submits a review on it.
# Usage: demo/features-setup.sh [owner/repo]   (needs gh and git; the repo needs the demo/go-discounts branch)
set -eu
R=${1:-BSchrift/nvim-reviewer-sandbox}
dir=$(mktemp -d)
gh repo clone "$R" "$dir" -- -q
cd "$dir"

# CI, once: go vet and go test on every PR, so the overview has checks to show.
if [ ! -f .github/workflows/ci.yml ]; then
  mkdir -p .github/workflows
  cat > .github/workflows/ci.yml <<'EOF'
name: CI
on:
  pull_request:
  push:
    branches: [main]
jobs:
  vet:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with: { go-version: '1.22' }
      - run: go vet ./...
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with: { go-version: '1.22' }
      - run: go test ./...
EOF
  git add .github && git commit -qm 'Add CI' && git push -q origin main
fi

branch=demo/promo-$(date +%s)
git checkout -q -b "$branch" origin/demo/go-discounts
git push -q -u origin "$branch"
url=$(gh pr create -R "$R" --base main --head "$branch" --title 'Add promo codes to the cart' \
  --body 'Adds SAVE10 and FIVEOFF promo codes. `Cart.ApplyCode` checks the code and `Total` applies it.')
n=${url##*/}

# Round 1: your review of the first commit.
gh api "repos/$R/pulls/$n/reviews" --input - >/dev/null <<EOF
{ "commit_id": "$(git rev-parse HEAD)", "event": "COMMENT", "body": "Two things before this goes in.",
  "comments": [
    { "path": "cart/cart.go", "line": 31, "side": "RIGHT", "body": "Clamping hides bugs in the caller. Reject qty < 1 instead?" },
    { "path": "discount/discount.go", "line": 11, "side": "RIGHT", "body": "FIVEOFF takes a \$3 order to \$0. Should it need a minimum order?" } ] }
EOF

# Round 2: the author's follow-up, with an error message for you to improve on camera.
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
		{"NOPE", 2000, 2000},
	} {
		if got := Apply(tc.code, tc.subtotal); got != tc.want {
			t.Errorf("Apply(%q, %d) = %d, want %d", tc.code, tc.subtotal, got, tc.want)
		}
	}
}
EOF
git add -A && git commit -qm 'Reject bad quantities; FIVEOFF needs a $10 order' && git push -q
gh pr comment "$n" -R "$R" --body 'Thanks! Quantities are validated now, and FIVEOFF needs a $10 order (with tests). Ready for another look.' >/dev/null

# Wait for CI, so the overview shows finished checks.
until gh pr checks "$n" -R "$R" >/dev/null 2>&1; do sleep 5; done
gh pr checks "$n" -R "$R" --watch >/dev/null 2>&1 || true
rm -rf "$dir"
echo "$url"
