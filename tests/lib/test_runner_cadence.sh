#!/usr/bin/env bash
# tests/lib/test_runner_cadence.sh — fails when the LATEST_RUNNERS table's
# 'Reviewed YYYY-MM-DD' stamp in bin/housekeeper-freshness is older than 180
# days, surfacing silent runner-label staleness as a visible test signal.

test_runner_cadence_stamp_is_fresh() {
    local repo="$REPO_ROOT"
    local engine="$repo/plugins/code-review-suite/bin/housekeeper-freshness"

    if [[ ! -f "$engine" ]]; then
        skip "runner cadence stamp" "engine not present"
        return
    fi

    local stamp
    stamp=$(grep -oE 'Reviewed [0-9]{4}-[0-9]{2}-[0-9]{2}' "$engine" | head -n1 | awk '{print $2}')
    if [[ -z "$stamp" ]]; then
        fail "runner cadence stamp: LATEST_RUNNERS has a 'Reviewed YYYY-MM-DD' stamp" \
            "no 'Reviewed YYYY-MM-DD' comment found near LATEST_RUNNERS"
        return
    fi

    local stamp_epoch now_epoch age_days
    # BSD date (macOS) and GNU date (Linux) differ; try both.
    stamp_epoch=$(date -j -f "%Y-%m-%d" "$stamp" "+%s" 2>/dev/null || date -d "$stamp" "+%s" 2>/dev/null)
    now_epoch=$(date "+%s")
    if [[ -z "$stamp_epoch" ]]; then
        fail "runner cadence stamp: stamp '$stamp' parses as a date" "date parse failed"
        return
    fi
    age_days=$(( (now_epoch - stamp_epoch) / 86400 ))
    if (( age_days <= 180 )); then
        pass "runner cadence stamp: LATEST_RUNNERS reviewed ${age_days}d ago (<= 180)"
    else
        fail "runner cadence stamp: LATEST_RUNNERS reviewed within 180 days" \
            "stamp '$stamp' is ${age_days} days old — re-verify the latest runner labels (ubuntu/windows/macos) against GitHub's runner-images releases and bump the 'Reviewed' date"
    fi
}
