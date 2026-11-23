#!/usr/bin/env bash
# Apply our local changes to the upstream third-party submodules.
#
#   scripts/deploy/apply-third-party-patches.sh [megalon|knowhere|all]   (default: all)
#
# The submodules systems/megalon/src (dassl-uiuc/MEGALON-artifact) and
# workloads/rag/vectordb/vectorDB/external/knowhere (zilliztech/knowhere) are pinned
# to unmodified upstream commits, because our commits cannot be pushed upstream.
# Our changes live in this repo as `git format-patch` series. This script creates
# a local branch `destijl` in each submodule = upstream base + `git am` of the
# series, and checks that the resulting tree equals the tree of the commit our
# builds were made from (commit hashes differ after `git am`; the tree hash is
# the byte-identity check).
#
# Run after `git clone --recurse-submodules` (or `git submodule update --init`).
# Idempotent: a submodule already at the expected tree is left alone.
# Never resets, cleans or deletes anything; refuses on a dirty submodule.
set -euo pipefail

REPO=$(cd "$(dirname "$(realpath "$0")")/../.." && pwd)

# name | submodule path | upstream base commit | patch dir | expected tree | original commit (our repo)
TABLE=(
  "megalon|systems/megalon/src|3be2fa78c51d136df2ffcf8609e3e4868e7f74c7|systems/megalon/patches|8ca4a2fbd5c731e8451cb4ea73bc5025f6d74fde|0ad3d29abdbd08e003a56af2feef63d2829c50db"
  "knowhere|workloads/rag/vectordb/vectorDB/external/knowhere|10473ff04f33633dffff323840e56b0911eb2d23|workloads/rag/vectordb/vectorDB/patches/knowhere|5320cf61a4dce946a338818280c03da964bb1bae|3c130ea1a6336ea014332be11b5adabbb876576b"
)

want=${1:-all}
case $want in megalon|knowhere|all) ;; *) echo "usage: $0 [megalon|knowhere|all]" >&2; exit 2 ;; esac

rc=0
for row in "${TABLE[@]}"; do
  IFS='|' read -r name path base pdir tree orig <<<"$row"
  [ "$want" = all ] || [ "$want" = "$name" ] || continue
  sm=$REPO/$path
  if ! git -C "$sm" rev-parse --git-dir >/dev/null 2>&1; then
    echo "$name: $path is not initialized; run: git -C $REPO submodule update --init $path" >&2; rc=1; continue
  fi
  have=$(git -C "$sm" rev-parse 'HEAD^{tree}')
  if [ "$have" = "$tree" ]; then
    echo "$name: already at the patched tree $tree ($(git -C "$sm" rev-parse --short HEAD))"; continue
  fi
  if [ -n "$(git -C "$sm" status --porcelain --untracked-files=no)" ]; then
    echo "$name: $path has uncommitted changes; refusing" >&2; rc=1; continue
  fi
  if ! git -C "$sm" cat-file -e "$base^{commit}" 2>/dev/null; then
    git -C "$sm" fetch --quiet origin "$base" || { echo "$name: cannot fetch base $base" >&2; rc=1; continue; }
  fi
  if git -C "$sm" rev-parse --verify --quiet refs/heads/destijl >/dev/null; then
    echo "$name: branch 'destijl' exists but is not at the expected tree; inspect it, nothing changed" >&2; rc=1; continue
  fi
  git -C "$sm" checkout --quiet -b destijl "$base"
  git -C "$sm" -c user.name="third-party patches" -c user.email="patches@localhost" \
      am --quiet --committer-date-is-author-date "$REPO/$pdir"/*.patch
  got=$(git -C "$sm" rev-parse 'HEAD^{tree}')
  if [ "$got" = "$tree" ]; then
    echo "$name: patched, branch destijl at $(git -C "$sm" rev-parse --short HEAD), tree $got = tree of original commit ${orig:0:9}"
  else
    echo "$name: tree mismatch after git am: got $got, want $tree" >&2; rc=1
  fi
done
exit $rc
