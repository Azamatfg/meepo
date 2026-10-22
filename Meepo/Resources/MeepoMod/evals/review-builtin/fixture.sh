#!/bin/sh
# A committed cart, then an uncommitted change with a bug: the discount is added, not taken off.
set -e
git init -q
printf 'def total(prices):\n    return sum(prices)\n' > cart.py
git add . && git -c user.email=e@e -c user.name=e commit -qm "cart total"
cat > cart.py <<'PY'
def total(prices, discount=0):
    """Total after a percentage discount (0-100)."""
    return sum(prices) * (1 + discount / 100)
PY
