#!/bin/bash
# Format Cantio Swift files after Edit/Write. Fail-soft so a missing formatter
# never blocks Claude.

set +e

# Read the JSON payload from stdin (Claude Code passes hook context this way).
payload=$(cat)
file_path=$(echo "$payload" | /usr/bin/python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('tool_input', {}).get('file_path', ''))" 2>/dev/null)

# Only act on Swift sources inside Cantio/ or CantioTests/.
case "$file_path" in
  *.swift)
    case "$file_path" in
      */Cantio/*|*/CantioTests/*) ;;
      *) exit 0 ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac

# Prefer swiftformat (most common), fall back to swift-format if Apple's tool is installed.
if command -v swiftformat >/dev/null 2>&1; then
  swiftformat --quiet "$file_path" >/dev/null 2>&1 || true
elif command -v swift-format >/dev/null 2>&1; then
  swift-format format -i "$file_path" >/dev/null 2>&1 || true
fi

exit 0
