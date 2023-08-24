#bisect helpers

log() { local msg=$1
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ")   $msg" >> "$INFO_LOG"
}

short_hash() { local rev=$1
  git rev-parse --short "$rev"
}

prepare_conf_for_update() {
  [[ -f $CONF_NAME ]] || echo "{}" > "$CONF_NAME"
  mktemp
}

#n.b since we're using -r, there is no difference between "100" and 100 even if in the json they
# are represented as a string and number respectively
get_conf_val() { local key=$1
  if [ ! -f "$CONF_NAME" ]; then
    echo ""
  else
    val=$(jq -r "$key" "$CONF_NAME")
    if [[ "$val" == "null" ]]; then
      echo ""
    else
      echo "$val"
    fi
  fi
}

set_conf_val() { local key=$1; local val=$2
  tmp_file=$(prepare_conf_for_update)
  jq "$key = \"$val\"" "$CONF_NAME" > "$tmp_file" && mv "$tmp_file" "$CONF_NAME"
}

set_num_conf_val() { local key=$1; local val=$2
  tmp_file=$(prepare_conf_for_update)
  jq "$key = $val" "$CONF_NAME" > "$tmp_file" && mv "$tmp_file" "$CONF_NAME"
}

save_results() { local hash=$1; local test=$2
  tmp_file=$(prepare_conf_for_update)
  #delete any existing result
  jq "del(.hashResults.\"$hash\")" "$CONF_NAME" > "$tmp_file" && mv "$tmp_file" "$CONF_NAME"
  #glob must be unquoted so the shell expands
  for file in artifacts/$hash*/$test/run_*/*.perf/stats.json; do
    value=$(jq_exec "$file")
    append_result "$hash" "$value"
  done
}

append_result() { local hash=$1; local result=$2;
  tmp_file=$(prepare_conf_for_update)
  jq ".hashResults.\"$hash\" += [$result]" "$CONF_NAME" > "$tmp_file" && mv "$tmp_file" "$CONF_NAME"
}

hash_metric() { local hash=$1; local metric=$2
  case $metric in
    average|avg)
      average_ops "$hash"
      ;;
    median|med)
      median_ops "$hash"
      ;;
    *)
      echo "Unknown metric: $metric"
      exit 1
      ;;
  esac
}

#round the result so it plays nicely in bash
average_ops() { local hash=$1
  jq -r ".hashResults.\"$hash\" | add / length | rint" "$CONF_NAME" || get_conf_val ".hashResults.\"$hash\""
}

median_ops() { local hash=$1
  jq -r ".hashResults.\"$hash\" | sort | if length % 2 == 0 then [.[length/2 - 1, length/2]] | add / 2 | rint else .[length/2|floor] end" "$CONF_NAME"  || get_conf_val ".hashResults.\"$hash\""
}

jq_exec() {
  jq_expression=$'group_by(.Elapsed) |
        map(
          {
            elapsed: (.[0].Elapsed / 1000000000) | rint,
            count: map(.Hist.Counts | add) | add
          }
        ) |
        ( (([.[].count] | add)) / ([.[].elapsed] | add) | rint )'

  jq -sc "$jq_expression" $@
}

# Ensure the CPU quota is high enough to account for number of concurrent runs
# cpu-quota >= (number of concurrent runs) * (cluster size) * (CPU per node)
test_hash() { local hash=$1; local test=$2; local count=$3; local cloud=$4
  {
    abase="artifacts/${hash}"
    if [ -d "$abase/$test" ]; then
      echo "[$hash] Using stats from existing run"
      return
    fi

    echo "[$hash] Running..."

    args=(
      "run" "^${test}\$"
      "--port" "$((8080+RANDOM % 1000))"
      "--workload" "${abase}/workload"
      "--cockroach" "${abase}/cockroach"
      "--artifacts" "${abase}/"
      "--count" "${count}"
      "--cpu-quota" "640"
      "--cloud" "${cloud}"
    )
    args+=("${@:5}")
    "${abase}/roachtest" "${args[@]}"
  } &> "$BISECT_DIR/$hash-test.log"
}

build_hash() { local hash=$1; local duration_override_mins=$2
 {
    git reset --hard
    git checkout "$hash"

    fullsha=$(git rev-parse "$hash")

    abase="artifacts/${hash}"
    mkdir -p "${abase}"

    # Locations of the binaries.
    rt="${abase}/roachtest"
    wl="${abase}/workload"
    cr="${abase}/cockroach"

    if [ ! -f "${cr}" ]; then
      if gsutil cp "gs://cockroach-edge-artifacts-prod/cockroach/cockroach.linux-gnu-amd64.$fullsha" "${cr}"; then
          echo "Copied cockroach binary from GCS"
      else
          ./dev build "cockroach-short" --cross=linux
          cp "artifacts/cockroach-short" "${cr}"
      fi
    fi

    if [ ! -f "${wl}" ]; then
      if gsutil cp "gs://cockroach-edge-artifacts-prod/cockroach/workload.$fullsha" "${wl}"; then
        echo "Copied workload from GCS"
      else
        ./dev build workload --cross=linux
        cp "artifacts/workload" "${wl}"
      fi
    fi

    if [ ! -f "${rt}" ]; then
      if [[ -n $duration_override_mins ]]; then
        echo "Building roachtest with duration override of $duration_override_mins mins"
        sed -i "s/opts\.duration = 30 \* time\.Minute/opts.duration = $duration_override_mins * time.Minute/"  pkg/cmd/roachtest/tests/kv.go || exit 2
        sed -i "s/ifLocal(c, \"10s\", \"30m\")/ifLocal(c, \"10s\", \"${duration_override_mins}m\")/"  pkg/cmd/roachtest/tests/ycsb.go || exit 2
        echo "duration override: $duration_override_mins mins" > "$abase/_dirty"
      fi
      ./dev build roachtest
      cp "bin/roachtest" "${rt}"
    fi

    chmod +x "$cr" "$wl" "$rt"
    git reset --hard
  } &> "$BISECT_DIR/$hash-build.log"
}

# if ops == -1, this is a trapped ^C from which we want to collect user input
prompt_user() { local hash=$1; local ops=$2; local metric=$3

  echo -ne '\a'
  if [[ ops -gt 0 ]]; then
    PS3="[$hash] $metric ops/s is $ops. Choose: "
  else
    PS3="[$hash] Interrupt: mark current and continue, or just quit?"
  fi

  select ch in Good Bad Skip Quit
  do
    case $ch in
    "Good")
      if [[ ops -gt 0 ]]; then
        log "[$hash] $metric ops/s: [$ops]. User marked as good. Threshold updated."
        set_num_conf_val ".thresholds.$metric.good" "$ops"
      else
        set_conf_val ".hashResults.\"$hash\"" "USER_GOOD"
        log "[$hash] Interrupted. User marked as good. Bisection will restart with updated bounds"
      fi
      return 0;;
    "Bad")
      if [[ ops -gt 0 ]]; then
        log "[$hash] $metric ops/s: [$ops]. User marked as bad. Threshold updated."
        set_num_conf_val ".thresholds.$metric.bad" "$ops"
      else
        set_conf_val ".hashResults.\"$hash\"" "USER_BAD"
        log "[$hash] Interrupted. User marked as bad. Bisection will restart with updated bounds"
      fi
      return 1;;
    "Skip")
      if [[ ops -gt 0 ]]; then
        log "[$hash] $metric ops/s: [$ops]. User skipped."
      else
        set_conf_val ".hashResults.\"$hash\"" "USER_SKIP"
        log "[$hash] Interrupted. User skipped"
      fi
      return 125;;
    "Quit")
      return 200;;
    *)
      echo "Enter a valid choice";;
    esac
  done
}

[[ -n $BISECT_DIR ]] || export BISECT_DIR="."
[[ -d ./pkg/cmd/cockroach ]] || { echo "bisection must be run from cockroach root"; return 1; }

mkdir -p "$BISECT_DIR"

export BISECT_LOG="$BISECT_DIR/bisect.log"
export INFO_LOG="$BISECT_DIR/info.log"
export CONF_NAME="$BISECT_DIR/config.json"
export GCE_PROJECT=cockroach-ephemeral
