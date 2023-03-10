#!/bin/bash

set -ex

#these can be parameterised
test="kv0/enc=false/nodes=3/batch=16"
branch="origin/master"
cloud="aws"
count=3
duration_mins=10
# median|average
metric="median"

#use dates OR hashes, but not both
#from="2023-02-02 09:00:00Z"
#to="2023-02-04 22:00:00Z"
goodHash=44d9f3c8b7bd46839187cea69eaec640c080ac05
badHash=5fbcd8a8deac0205c7df38e340c1eb9692854383

#bisect_dir="${test//[^[:alnum:]]/-}/${branch//[^[:alnum:]]/-}/$from,$to"
#explicity set bisect dir, and make visible to bisect-util.sh
export BISECT_DIR=/home/miral/workspace/bisections/issues/97790

# first-parent is goodHash for release branches where we generally know the merge parents are OK
# git bisect start --first-parent
BISECT_START_CMD="git bisect start"

SCRIPT_DIR=$(dirname "$0")
. "$SCRIPT_DIR"/bisect-util.sh

git reset --hard

trapped() {
  #we need to be able to collect a non-zero return code from prompt_user
  set +e
  echo "interrupt!"
  prompt_user "$(short_hash HEAD)" "-1" "$metric"

  if [[ $? -gt 125 ]]; then
    exit 1
  fi

  # relaunch this script and restart bisection with updated config
  exec "$0" "$@"
}

trap 'trapped' INT

# the bisect replay is not even really required since we can effectively
# use the json to view saved results
if [ -f "$BISECT_LOG" ]; then
  echo "Bisect log found. Replaying"
  $BISECT_START_CMD
  git bisect replay "$BISECT_LOG"
else
  if [[ -z $goodHash || -z $badHash ]]; then
    [[ -n $from && -n $to ]] || { echo "You must specify (good AND bad hashes) OR (to AND from dates)"; exit 1; }
    hashes="$(git log "$branch" --merges --pretty=format:'%h' --date=short --since "$from" --until "$to")"
    goodHash=$(echo "$hashes" | tail -1)
    badHash=$(echo "$hashes" | head -1)
  else
    goodHash="$(short_hash "$goodHash")"
    badHash="$(short_hash "$badHash")"
  fi

  goodVal=$(hash_metric "$goodHash" "$metric")

  # running in parallel is fine, but building saturates CPU so we do that synchronously
  if [ -z "$goodVal" ]; then
   echo "[$goodHash] No good threshold found. Will build/run this hash to collect an initial good value."
   build_hash "$goodHash" "$duration_mins"
   test_hash "$goodHash" "$test" $count "$cloud" &
  fi

  badVal=$(hash_metric "$badHash" "$metric")
  if [ -z "$badVal" ]; then
   echo "[$badHash] No bad threshold specified. Will build/run this hash to collect an initial bad value."
   build_hash "$badHash" "$duration_mins"
   test_hash "$badHash" "$test" $count "$cloud" &
  fi

  wait

  # testing this variable again here as a way to determine whether we ran the test above
  if [ -z "$goodVal" ]; then
    save_results "$goodHash" "$test"
    goodVal=$(hash_metric "$goodHash" "$metric")
  fi

  if [ -z "$badVal" ]; then
    save_results "$badHash" "$test"
    badVal=$(hash_metric "$badHash" "$metric")
  fi

  [[ goodVal -gt badVal ]] || { echo "Initial good threshold [$goodVal] must be > initial bad threshold [$badVal]. Cannot bisect. Aborting."; exit 1;  }

  set_num_conf_val ".thresholds.$metric.good" "$goodVal"
  set_num_conf_val ".thresholds.$metric.bad" "$badVal"

  log "Bisecting regression in [$test] using commit range [$goodHash (known good),$badHash (known bad)]"
  log "Thresholds [good >= $goodVal, bad <= $badVal]"

  $BISECT_START_CMD
  git bisect good "$goodHash"
  git bisect bad "$badHash"
fi

git bisect run "$SCRIPT_DIR"/bisect.sh "$test" "$count" "$duration_mins" "$cloud" "$metric"

log "Bisection complete. Suspect commit:"
git bisect visualize &>> "$INFO_LOG"

git bisect log > "$BISECT_LOG"
