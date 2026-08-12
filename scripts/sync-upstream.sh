#!/usr/bin/env bash
# Merge upstream/main into the current fork branch.
#
# Generated artifacts are committed AND byte-compared by drift tests, so they
# conflict on almost every sync. Hand-merging them is always wrong — the fix is
# to regenerate. This script resolves those paths automatically and leaves every
# real conflict for you.
set -euo pipefail

GENERATED=(
	"backend/internal/httpd/apispec/openapi.yaml"
	"frontend/src/api/schema.ts"
	"frontend/src/renderer/routeTree.gen.ts"
	"backend/internal/storage/sqlite/gen"
)

cd "$(git rev-parse --show-toplevel)"

if [[ -n "$(git status --porcelain)" ]]; then
	echo "working tree is dirty — commit or stash first" >&2
	exit 1
fi

branch="$(git rev-parse --abbrev-ref HEAD)"
echo "==> fetching upstream"
git fetch upstream main

behind="$(git rev-list --count "HEAD..upstream/main")"
if [[ "$behind" == "0" ]]; then
	echo "already up to date with upstream/main"
	exit 0
fi
echo "==> $behind upstream commit(s) to merge into $branch"

# Show what is about to land in the churn-prone wire-up files, before merging.
echo "==> upstream changes in files this fork also edits:"
git diff --name-only "HEAD...upstream/main" -- \
	backend/internal/httpd/controllers \
	backend/internal/session_manager \
	backend/internal/ports \
	backend/internal/storage/sqlite \
	backend/internal/adapters/runtime |
	sed 's/^/    /' || true

merge_ok=0
git merge --no-edit upstream/main || merge_ok=$?

if [[ "$merge_ok" -ne 0 ]]; then
	# Take upstream's side for generated files, then regenerate over the top.
	for path in "${GENERATED[@]}"; do
		if git diff --name-only --diff-filter=U | grep -q "^${path}"; then
			echo "==> taking upstream side of generated path: $path (will regenerate)"
			git checkout --theirs -- "$path" 2>/dev/null || true
			git add -- "$path"
		fi
	done

	remaining="$(git diff --name-only --diff-filter=U || true)"
	if [[ -n "$remaining" ]]; then
		echo
		echo "==> real conflicts left for you:"
		echo "$remaining" | sed 's/^/    /'
		echo
		echo "resolve them, then: npm run sqlc && npm run api && git commit"
		exit 1
	fi
fi

echo "==> regenerating derived artifacts"
npm run sqlc
npm run api

if [[ -n "$(git status --porcelain)" ]]; then
	git add -A
	git commit --no-edit || true
fi

echo "==> verifying"
(cd backend && go build ./... && go test ./...)

echo "done. review, then: git push origin $branch"
