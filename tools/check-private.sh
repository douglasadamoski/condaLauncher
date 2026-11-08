#!/usr/bin/env bash
# Refuse to commit machine- or person-specific strings.
# Patterns come from local/private-patterns.txt (git-ignored, one extended regex per
# line) plus generic ones below. Runs on the staged files when installed as a hook:
#   ln -s ../../tools/check-private.sh .git/hooks/pre-commit
# or by hand over the whole tree:  tools/check-private.sh --all
set -uo pipefail
root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$root" || exit 2
pats=('(^|[^0-9])(10|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\.[0-9]+\.[0-9]+' '/mnt/[A-Za-z]' '/home/[a-z]')
if [ -r local/private-patterns.txt ]; then while IFS= read -r p; do [ -n "${p%%#*}" ] && pats+=("$p"); done < local/private-patterns.txt; fi
if [ "${1:-}" = --all ]; then mapfile -t files < <(git ls-files 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null)
else mapfile -t files < <(git diff --cached --name-only --diff-filter=ACM); fi
bad=0
for f in "${files[@]}"; do
  [ -f "$f" ] || continue
  for p in "${pats[@]}"; do
    if hits="$(grep -nEi -- "$p" "$f" 2>/dev/null)"; then
      # demo addresses are fine
      hits="$(printf '%s\n' "$hits" | grep -vE '127\.0\.0\.1|0\.0\.0\.0')" || true
      [ -n "$hits" ] || continue
      printf 'private string in %s (pattern %s):\n%s\n' "$f" "$p" "$(printf '%s\n' "$hits" | head -n 3 | sed 's/^/    /')"; bad=1
    fi
  done
done
[ "$bad" = 0 ] && echo "check-private: clean (${#files[@]} files)"
exit "$bad"
