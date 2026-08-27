#!/usr/bin/env bash
# Run every flow, then wait for the last worker. Autonomous - walk away.
set -u
for f in flows/*.txt; do
  echo "=================================================================="
  echo "FLOW: $f"
  echo "=================================================================="
  python .claude/scripts/flow.py "$f"
  echo
done
echo "All flows done. Waiting 45s for the last detached worker..."
sleep 45
python .claude/scripts/inspect.py
