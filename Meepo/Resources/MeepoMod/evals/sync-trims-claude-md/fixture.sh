#!/bin/sh
# A CLAUDE.md with one rule worth keeping, one line the code already says, and one that's no longer true.
set -e
git init -q
cat > package.json <<'JSON'
{ "name": "shop", "scripts": { "test": "vitest" }, "devDependencies": { "vitest": "^3.0.0" } }
JSON
cat > CLAUDE.md <<'MD'
# Shop

- Prices are in tiyn (integers), never floats.
- The project uses TypeScript and has a package.json.
- Tests: `npm run jest`
MD
git add . && git -c user.email=e@e -c user.name=e commit -qm init
