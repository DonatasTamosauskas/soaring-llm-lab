#!/usr/bin/env bash
set -euo pipefail
SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $# -eq 1 ]] || { echo "Usage: $0 /absolute/path/to/new-example-root" >&2; exit 2; }
[[ "$1" = /* && ! -e "$1" ]] || { echo "Destination must be an absolute path that does not exist." >&2; exit 1; }
mkdir -p "$1/QuestBootstrap" "$1/Logs" "$1/scripts"
for DIR in Assets Packages ProjectSettings; do
  rsync -a --exclude='Resources/PerformanceTestRun*.json*' "$SOURCE/QuestBootstrap/$DIR/" "$1/QuestBootstrap/$DIR/"
done
cp "$SOURCE"/scripts/*.sh "$1/scripts/"
cp "$SOURCE/README.md" "$SOURCE/FINDINGS.md" "$SOURCE/THIRD_PARTY_NOTICES.md" "$SOURCE/VERIFICATION.md" "$SOURCE/.gitignore" "$1/"
printf 'Created %s\nRun %s/scripts/unity.sh setup, then %s/scripts/unity.sh play\n' "$1" "$1" "$1"
