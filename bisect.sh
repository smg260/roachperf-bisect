#!/bin/bash

test=$1
count=$2
duration_mins=$3

SCRIPT_DIR=$(dirname "$0")
. "$SCRIPT_DIR"/bisect-util.sh

CURRENT_HASH="$(short_hash HEAD)"

#first lets check our saved results
hashResults=$(get_conf_val ".hashResults.\"$CURRENT_HASH\"")

case $hashResults in
  USER_GOOD)
    exit 0
    ;;
  USER_BAD)
    exit 1
    ;;
  USER_SKIP)
    exit 128
    ;;
  "")
    build_hash "$CURRENT_HASH" "$duration_mins" &> "$BISECT_DIR/$CURRENT_HASH-build.log"
    test_hash "$CURRENT_HASH" "$test" "$count" &> "$BISECT_DIR/$CURRENT_HASH-run.log"
    save_results "$CURRENT_HASH" "$test"
    ;;
  *) # we have saved results
    ;;
esac

avgOps=$(avg_ops "$CURRENT_HASH")
goodThreshold=$(get_conf_val ".goodThreshold")
badThreshold=$(get_conf_val ".badThreshold")

if [ -n "$goodThreshold" ] && [[ avgOps -ge goodThreshold ]]; then
  log "[$CURRENT_HASH] Average ops/s: [$avgOps]. Auto marked as good." "$LOG_NAME"
  exit 0;
elif [ -n "$badThreshold" ] && [[ avgOps -le badThreshold ]]; then
  log "[$CURRENT_HASH] Average ops/s: [$avgOps]. Auto marked as bad." "$LOG_NAME"
  exit 1;
else
  # we don't have thresholds to compare, or the value doesn't meet them
  prompt_user "$CURRENT_HASH" "$avgOps"
fi
