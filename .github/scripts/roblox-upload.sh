#!/usr/bin/env bash
# Updates the plugin's Roblox asset through Open Cloud (assets v1): the rbxm content, then the description, which is
# .github/store-description.txt plus the version, the date and the commits since the previous tag. Run by the release
# workflow's roblox job from a full checkout, with TypeTorchSync.rbxm in the working directory.
# Env: API_KEY, ASSET_ID, ASSET_TYPE (default Plugin), GITHUB_REF_NAME (the tag).
set -euo pipefail

api=https://apis.roblox.com/assets/v1
type=${ASSET_TYPE:-Plugin}
tmp=${RUNNER_TEMP:-$(mktemp -d)}

# PATCH the asset; $1 = query string, rest = extra curl args. Waits for the operation if one comes back.
patch() {
	local query=$1
	shift
	local code
	code=$(curl -sS -o "$tmp/patch.json" -w '%{http_code}' -X PATCH "$api/assets/$ASSET_ID$query" \
		-H "x-api-key: $API_KEY" "$@")
	cat "$tmp/patch.json"
	echo
	if [ "$code" != 200 ]; then
		echo "::error::Open Cloud PATCH$query returned HTTP $code"
		exit 1
	fi
	local operation
	operation=$(jq -r '.path // empty' "$tmp/patch.json")
	case "$operation" in operations/*) ;; *) return 0 ;; esac
	for _ in $(seq 1 30); do
		sleep 2
		curl -sSf -o "$tmp/op.json" -H "x-api-key: $API_KEY" "$api/$operation"
		if [ "$(jq -r '.done // false' "$tmp/op.json")" = true ]; then
			cat "$tmp/op.json"
			echo
			if ! jq -e '.response' "$tmp/op.json" >/dev/null; then
				echo "::error::Open Cloud rejected PATCH$query"
				exit 1
			fi
			return 0
		fi
	done
	echo "::error::operation $operation not done after 60 s"
	exit 1
}

# Content.
request=$(jq -cn --arg type "$type" --arg id "$ASSET_ID" '{assetType: $type, assetId: $id}')
patch "" -F "request=$request" -F "fileContent=@TypeTorchSync.rbxm;type=model/x-rbxm"
echo "::notice::asset $ASSET_ID content updated to $GITHUB_REF_NAME"

# Description: the store text, then version, date and what changed since the previous tag (newest first, no merges).
previous=$(git describe --tags --abbrev=0 --match 'v*' "$GITHUB_REF_NAME^" 2>/dev/null || true)
range=${previous:+$previous..}$GITHUB_REF_NAME
changes=$(git log --no-merges --format='- %s' "$range" | grep -v -E '^- release v?[0-9]' | head -n 6 || true)
{
	cat .github/store-description.txt
	printf '\n%s, updated %s UTC\n' "$GITHUB_REF_NAME" "$(date -u +%Y-%m-%d)"
	if [ -n "$changes" ]; then
		printf '\nWhat changed%s:\n%s\n' "${previous:+ since $previous}" "$changes"
	fi
} >"$tmp/description.txt"
# Roblox caps asset descriptions at 1000 characters: cut whole lines from the end of the change list.
while [ "$(wc -m <"$tmp/description.txt")" -gt 1000 ]; do
	sed -i '$d' "$tmp/description.txt"
done
cat "$tmp/description.txt"
request=$(jq -cn --arg type "$type" --arg id "$ASSET_ID" --rawfile description "$tmp/description.txt" \
	'{assetType: $type, assetId: $id, description: ($description | rtrimstr("\n"))}')
patch "?updateMask=description" -F "request=$request"
echo "::notice::asset $ASSET_ID description updated"
