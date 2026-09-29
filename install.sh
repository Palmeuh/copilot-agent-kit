#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dest="${COPILOT_HOME:-$HOME/.copilot}"
mkdir -p "$dest"/{agents,hooks,scripts,skills}

# Link $1 into directory $2, skipping files that already resolve to the repo file
# (ln -sf errors with "are the same file" in that case).
link() {
  local src="$1" dir="$2"
  if [ "$src" -ef "$dir/$(basename "$src")" ]; then return 0; fi
  ln -sf "$src" "$dir/"
}

for f in "$here"/agents/*.agent.md; do link "$f" "$dest/agents"; done
for f in "$here"/hooks/*.sh;        do link "$f" "$dest/hooks"; chmod +x "$f"; done
for f in "$here"/hooks/*.json;      do link "$f" "$dest/hooks"; done
for f in "$here"/scripts/*.sh;      do link "$f" "$dest/scripts"; chmod +x "$f"; done
for d in "$here"/skills/*/; do
  name="$(basename "$d")"
  if ! [ "${d%/}" -ef "$dest/skills/$name" ]; then
    ln -sfn "${d%/}" "$dest/skills/$name"
  fi
done
echo "installed into $dest (agents, skills, hooks, scripts)"
