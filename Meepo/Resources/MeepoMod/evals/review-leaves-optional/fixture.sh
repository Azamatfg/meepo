#!/bin/sh
# An uncommitted change that works, with only a nit in it: a magic number.
set -e
git init -q
printf 'def total(prices):\n    return sum(prices)\n' > cart.py
git add . && git -c user.email=e@e -c user.name=e commit -qm "cart total"
cat > cart.py <<'PY'
def total(prices):
    return sum(prices)


def with_tax(prices):
    return total(prices) * 1.12
PY
