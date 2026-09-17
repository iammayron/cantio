#!/bin/bash
# Print a quick session-start summary so the agent has fresh context.

set +e

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 0

echo "=== Cantio session ==="
echo "Branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'no-git')"
echo "Last commit: $(git log -1 --oneline 2>/dev/null || echo 'none')"

if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  echo "Uncommitted changes:"
  git status --porcelain | head -20
else
  echo "Working tree clean."
fi

# Check most recent test run age.
latest=$(ls -t /Users/mayron/Library/Developer/Xcode/DerivedData/Cantio-*/Logs/Test/*.xcresult 2>/dev/null | head -1)
if [ -n "$latest" ]; then
  age_sec=$(( $(date +%s) - $(stat -f %m "$latest" 2>/dev/null || echo 0) ))
  age_min=$(( age_sec / 60 ))
  echo "Last test run: ${age_min}m ago"
else
  echo "No test runs recorded."
fi

exit 0
