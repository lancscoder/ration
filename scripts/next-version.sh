#!/bin/sh
# Prints the version for the next release.
# VERSION holds the minimum: if it's ahead of the latest v* tag it is used as is
# (that's how to bump minor/major); otherwise the latest tag's patch goes up by one.
set -eu
cd "$(dirname "$0")/.."
base=$(tr -d '[:space:]' < VERSION)
latest=$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
if [ -z "$latest" ]; then
  echo "$base"
  exit 0
fi
highest=$(printf '%s\n%s\n' "$base" "$latest" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
if [ "$highest" = "$base" ] && [ "$base" != "$latest" ]; then
  echo "$base"
else
  major=${latest%%.*}; rest=${latest#*.}; minor=${rest%%.*}; patch=${rest#*.}
  echo "$major.$minor.$((patch + 1))"
fi
