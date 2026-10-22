#!/bin/sh
set -e
git init -q
printf '# Shop\n\nA web shop: cart, checkout, orders.\n' > README.md
git add . && git -c user.email=e@e -c user.name=e commit -qm init
