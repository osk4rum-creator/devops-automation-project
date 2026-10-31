#!/usr/bin/env bash
# Plugin lockfile generator.
#
# jenkins/plugins.txt lists the plugins we chose. Each one depends on many
# others (~90 in total). Pinning only the 12 top-level plugins is NOT enough:
# Jenkins then picks dependency versions itself, and with "oldest allowed"
# resolution some plugins conflict and fail to load (this happened - see README).
#
# This script asks the official jenkins-plugin-cli (inside the pinned Jenkins
# image) for a compatible set, then writes EVERY plugin with its exact version
# into the installPlugins block of jenkins/values.yaml. Result: every install
# gets byte-for-byte the same plugins.
#
# Usage: ./scripts/lock-plugins.sh      (then ./scripts/configure-jenkins.sh)
set -euo pipefail
cd "$(dirname "$0")/.."

JENKINS_IMAGE="jenkins/jenkins:$(grep -E '^\s+tag: "[0-9.]+-jdk[0-9]+"' jenkins/values.yaml | head -1 | sed -E 's/.*"(.*)".*/\1/')"
WORK="$(mktemp -d)"
grep -vE '^\s*(#|$)' jenkins/plugins.txt > "$WORK/plugins.txt"

echo "==> Resolving plugins for $JENKINS_IMAGE"
MSYS_NO_PATHCONV=1 docker run --rm --entrypoint jenkins-plugin-cli \
  -v "$(cd "$WORK" && pwd -W 2>/dev/null || pwd):/work" "$JENKINS_IMAGE" \
  --plugin-file /work/plugins.txt --latest true --list --no-download > "$WORK/resolved.txt" 2>&1
  # (jenkins-plugin-cli prints its list to stderr, hence 2>&1)

# Section "Plugins that will be downloaded:" lists "name version" pairs
sed -n '/Plugins that will be downloaded:/,$p' "$WORK/resolved.txt" \
  | grep -E '^[a-z0-9-]+ [^ ]+$' | awk '{print "    - "$1":"$2}' | sort -u > "$WORK/lock.yaml" || true
COUNT=$(wc -l < "$WORK/lock.yaml")
# Safety net: never overwrite values.yaml with an empty or partial list
if [ "$COUNT" -lt "$(wc -l < "$WORK/plugins.txt")" ]; then
  echo "ERROR: only $COUNT plugins resolved - output was:"; cat "$WORK/resolved.txt"; rm -rf "$WORK"; exit 1
fi
echo "==> $COUNT plugins resolved"

# Replace everything between the LOCK markers in values.yaml
awk -v lockfile="$WORK/lock.yaml" '
  /# BEGIN PLUGIN LOCK/ { print; while ((getline line < lockfile) > 0) print line; skip=1; next }
  /# END PLUGIN LOCK/   { skip=0 }
  !skip { print }
' jenkins/values.yaml > "$WORK/values.yaml"
mv "$WORK/values.yaml" jenkins/values.yaml
rm -rf "$WORK"
echo "==> jenkins/values.yaml updated. Apply with ./scripts/configure-jenkins.sh"
