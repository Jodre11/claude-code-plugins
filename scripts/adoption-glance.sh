#!/usr/bin/env bash
#
# adoption-glance.sh — one-screen GitHub-traffic adoption pulse for the
# plugin marketplace repo. Manually run; no storage, no scheduling, no history.
# Traffic endpoints are owner-only and report a 14-day rolling window.

set -euo pipefail

REPO="Jodre11/claude-code-plugins"

for tool in gh jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        case "$tool" in
            gh) hint="https://cli.github.com" ;;
            jq) hint="brew install jq" ;;
        esac
        printf 'error: %s is required (install: %s)\n' "$tool" "$hint" >&2
        exit 1
    fi
done

fetch() {
    # fetch <api-path> — echo JSON on success; on failure print a clear
    # message (403 => owner-token scope) and exit non-zero.
    local path="$1" out
    if ! out="$(gh api "$path" 2>&1)"; then
        if printf '%s' "$out" | grep -q "HTTP 403"; then
            printf 'error: %s returned 403 — traffic endpoints are owner-only; run `gh auth status` and ensure you are authenticated as the repo owner.\n' "$path" >&2
        else
            printf 'error: failed to fetch %s:\n%s\n' "$path" "$out" >&2
        fi
        exit 1
    fi
    printf '%s' "$out"
}

clones_json="$(fetch "repos/$REPO/traffic/clones")"
views_json="$(fetch "repos/$REPO/traffic/views")"
repo_json="$(fetch "repos/$REPO")"

clone_total="$(printf '%s' "$clones_json" | jq -r '.count')"
clone_unique="$(printf '%s' "$clones_json" | jq -r '.uniques')"
view_unique="$(printf '%s' "$views_json" | jq -r '.uniques')"
stars="$(printf '%s' "$repo_json" | jq -r '.stargazers_count')"
forks="$(printf '%s' "$repo_json" | jq -r '.forks_count')"

if [ "$clone_unique" -eq 0 ]; then
    per_person="n/a"
else
    per_person="$(printf '%s %s' "$clone_total" "$clone_unique" \
        | awk '{ printf "%.1f", $1 / $2 }')"
fi

printf '%s — adoption glance (14-day window)\n' "${REPO##*/}"
printf '  Unique cloners : %-10s ~how many different people\n' "$clone_unique"
printf '  Total clones   : %-10s pull volume\n' "$clone_total"
printf '  Clones/person  : %-10s ~how often each re-pulls (autoUpdate-driven)\n' "$per_person"
printf '  Unique viewers : %s\n' "$view_unique"
printf '  Stars / Forks  : %s / %s\n' "$stars" "$forks"
printf 'Caveat: anonymous; includes your own machines + CI; 14-day rolling; upper bound.\n'
