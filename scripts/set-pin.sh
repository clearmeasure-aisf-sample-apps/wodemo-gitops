#!/usr/bin/env bash
# Writes the three image pins of one environment: scripts/set-pin.sh <tdd|uat|prod> <version>
# Used by the GitHub Actions pin writer (sync-tdd.yml, promote.yml). Octopus Deploy does the same through its
# "Update Argo CD image tags" step once PIN_WRITER=octopus.
set -euo pipefail
env="${1:?environment (tdd|uat|prod)}"
version="${2:?version, for example 1.0.12}"
case "$env" in tdd | uat | prod) ;; *) echo "unknown environment: $env" >&2; exit 2 ;; esac
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "not a release version: $version" >&2; exit 2; }
file="wodemo/envs/${env}/kustomization.yaml"
[ -f "$file" ] || { echo "missing $file" >&2; exit 2; }
sed -i -E "s/^(    newTag: )\"[^\"]*\"/\1\"${version}\"/" "$file"
echo "pinned ${env} to ${version}"
grep -n "newTag" "$file"
