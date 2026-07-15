#!/usr/bin/env bash
# Safely apply a framework-only update tarball from Claude WITHOUT touching your
# data. Run from your project root:  ./update_framework.sh <framework.tar.gz>
#
# It extracts only the framework paths (see FRAMEWORK_MANIFEST.txt) into a temp
# dir, shows you a diff against your tree, and asks before copying. Your specs,
# inventories, and customized group_vars are never in the tarball and never
# touched.
set -euo pipefail
TARBALL="${1:?usage: ./update_framework.sh <framework.tar.gz>}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "[update] extracting framework to temp..."
tar -xzf "$TARBALL" -C "$TMP"
# Guard: refuse if the tarball contains any user-owned path.
if tar -tzf "$TARBALL" | grep -E '(^|/)(mydeployments|inv)/' >/dev/null; then
  echo "[update] REFUSING: tarball contains user-owned paths (mydeployments/ or inv/)."
  echo "         This should be a framework-only tarball. Aborting."
  exit 1
fi
echo "[update] changes vs your current tree:"
diff -ruq "$TMP" . 2>/dev/null | grep -vE 'Only in \.(/|$)' || true
read -r -p "[update] apply these framework files? [y/N] " ans
[ "$ans" = "y" ] || { echo "aborted"; exit 0; }
# copy framework files only (the tarball already contains only those)
( cd "$TMP" && find . -type f -print0 | xargs -0 -I{} cp --parents {} "$OLDPWD/" )
echo "[update] done. Your specs/inventories were untouched. Run 'git diff' to confirm."
