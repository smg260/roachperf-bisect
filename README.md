# Overview

This repository houses a set of bash scripts to help bisect a roach perf regression using `git bisect run`

At a high level:

- `bisect_runner.sh` is the executable entry point, in which user specifies args (see section below)
- if starting good/bad thresholds are not specified in the `config.json`, both good and bad hashes are run via roachtest to collect a baseline
- `git bisect` is used to progress through hashes
- each chosen hash is built and run via roachtest with the result stored in the `config.json`
- the median or average of that result is used to determine if hash will then be marked good/bad/skipped/prompt for user input.
- eventually git bisect will arrive at a potential culprit commit
- subsequent runs or replays of the bisect will look in the config.json first

Note: the script will prompt the user for good/bad/skip/quit if a collected metric falls between the good and bad thresholds. If a user marks it as good or bad, the relevant threshold will be updated for future hashes.

# Prerequisites

1. bash/zsh
2. jq
3. cockroach/roachtest/roachprod can be built on the machine
4. roachprod can create a cluster (gce/aws permissions set up)

# Running a bisection

`git clone` this repository, and execute `bisect_runner.sh` from the cockroach root. Specify arguments below.

Note: These scripts *must* live outside the cockroach root otherwise they will get lost with each revision being bisected (hence this separate repo)

1. git clone this
2. edit `bisect_runner.sh` to update arguments (see Required arguments section)
3. `cd <cockroach_root>` (e.g. ~/go/src/github.com/cockroachdb/cockroach)
4. `./path_to_this_repo/bisect_runner.sh` (user will be prompted for input only if a metric falls between the bad and good thresholds)

After the script has completed, a commit will (hopefully) be identified. See logging below. Using a gce worker is highly recommended.

# Arguments for `bisect_runner.sh`

`bisect_runner.sh` is the entry point and where the following parameter values should be defined

##### *Required*

- `test` a single roach test e.g. `kv0/enc=false/nodes=3/batch=16`

- `cloud` cloud that the test runs on. Can be one of `gce,aws`

- `branch` the git branch e.g. `origin/master`

- `count` number of concurrent runs from which to collect a comparable metric e.g. `5`

- `metric` which metric to use for comparison. Can be one of `median,average`

- `goodHash` the hash of the last known good commit. See notes below to determine the good and bad hash.

- `badHash` the hash of the first known bad commit. See notes below to determine the good and bad hash.

##### *Optional*

- `BISECT_DIR` where log files and config.json are stored. e.g. `~/bisections/issues/97790` Default: cwd (i.e. cockroach root)

##### *Experimental - use with caution*

- `duration_mins` overrides the number of minutes a test runs for. Currently only `kv*` and `ycsb*` tests supported. Achieved via patching roachtest source.\
\
You should review the roachperf graphs to determine whether shortening the duration would yield a false result. Consider, for example, a perf graph which only shows a regression after 15 minutes. A duration of < 15 mins would return a false negative. However, if a graph shows a clear degradation in performance immediately compared to the good hash, it may make sense to shorten a 30 min test to something much less. (10 or 5 mins)

### Finding the appropriate good and bad hashes

Note the date on the roachperf dashboard where the regression was first observed. This date has a corresponding TeamCity nightly roachtest run, from which we can extract the `badHash`. Repeat for the previous date (where the metric is good), and you will have a `goodHash`. In both cases the hash is the one checked out by TC for that run.

# The config.json

The config json file is where all the results for roachtest runs for various benchmarks are stored. [Sample config.json](./sample_config.json) It is also used for a degree of resiliency should the script fail for any reason. You can simply re-run the script, which will look in the config.json first for any results before attempting to execute a roachtest.

As bisection progresses, the scripts will update and add entries to this file. An array of results is stored for every hash that is run. e.g. if `count=5`, you will see 5 numbers per hash corresponding to each run.

##### *Specifying starting thresholds*

When a good/bad hash is specified, the script will attempt to build/run both hashes to collect baseline before commencing the bisect. However, if you would like to specify reasonable thresholds beforehand and skip this step, manually add the corresponding numbers for each of the good and bad hash in the config.json.

e.g. you have identified good/bad hashes as `44d9f3c8b7`/`5fbcd8a8de` and already know that `15000/10000` are good threshold values. This is the relevant part of the `config.json` that should exist prior to executing the script:

```json
{
...
  "hashResults": {
     "44d9f3c8b7" : [15000],
     "5fbcd8a8de" : [10000]
  }
...
}
```

#### *User specified categorisation*

If the script cannot classify a result as good or bad, it will prompt with a menu `GOOD, BAD, SKIP` or `QUIT`. The good and bad thresholds will be updated if marked as good or bad (like a low and high watermark respectively). These values are obviously not updated in the case of the menu being shown via trap handling `CTRL^C` as there is no result.

For both cases the `config.json`, instead of an array of numeric results for the hash, will instead display a string value of `USER_GOOD, USER_BAD` or `USER_SKIP`.

```json
{
...
  "hashResults": {
     "44d9f3c8b7" : [15000],
     "5fbcd8a8de" : [10000],
     "6fgd23fe12" : "USER_SKIP",
     "87a4d5ee41" : "USER_BAD",
  }
...
}

```

# Logging

All logs are created in `BISECT_DIR`. There are logs created for building and running of each hash, and the 2 informational logs below:


- `info.log` shows progress of the bisection and will ultimately look something like

```plaintext
2023-02-28T16:59:44Z   Bisecting regression in [kv0/enc=false/nodes=3/batch=16] using commit range [44d9f3c8b7b (known good),5fbcd8a8dea (known bad)]
2023-02-28T16:59:44Z   Thresholds [good >= 1297, bad <= 1133]
2023-02-28T17:17:15Z   [1708ea4b2a2] median ops/s: [1144]. User marked as bad. Threshold updated.
2023-02-28T17:33:48Z   [ca70b824690] median ops/s: [1281]. User marked as good. Threshold updated.
2023-02-28T17:54:10Z   [ebc33fa0823] median ops/s: [1096]. Auto marked as bad.
2023-02-28T18:11:33Z   [c18156317dd] median ops/s: [1099]. Auto marked as bad.
2023-02-28T18:28:54Z   [702ff6fa87c] median ops/s: [1080]. Auto marked as bad.
2023-02-28T18:28:54Z   Bisection complete. Suspect commit:
commit 702ff6fa87c7494b240a16303ecf3e2a37c18e49
Author: Some User <someuser@gmail.com>
Date:   Thu Dec 22 13:23:57 2022 -0500

    kv: some commit description
```

The above shows an example where user input was required because the metric fell in between the good and bad thresholds.

- `bisect.log` is the output of running `git bisect log` and can be used to tweak/replay a bisection. See git documentation.

# Limitations

- Some roachperf graphs are noisy and and will be inherently difficult to bisect looking at just performance numbers. This can be mitigated by having as many concurrent runs as possible (>= 5). Even then, some bisections where results are borderline good or bad may arrive at an incorrect culprit commit.
- Only works for YCSB and KV benchmarks for now.
- Requires the good metric to be "higher" and the bad metric "lower". Easily changed but that is the assumption for now.
- Script trap handling is not bulletproof and as such if you kill the script early, it *may* not terminate the child processes.

# Improvements / TODOs


## Higher Priority

- (Simple) When a non merge commit is selected, we should merge it with the first parent before testing which will allow us to detect regressions which only manifest after a merge, and not necessarily within the commit itself.
- (Simple) Add other benchmarks like TPCC. Currently not supported just because of differing output paths of metrics
- (Simple) Support metric direction
- Pull metrics from GCE if they exist
- (Simple) Include commits only for specified paths - supported by git already
- Slack notifications when user input required
- Collect CPU/mem profiles at various times

## Lower Priority

- Use lightweight in-mem db instead of json file
- Search CI for pre-built binaries of a particular hash

# FAQ

##### Will this always find an offending commit?

No - In the case of noisy benchmarks and very slight regressions, the measured performance may not be clearly categorised as good or bad, in which case a user will be prompted for input; (Good|Bad|Skip|Quit).
A human may review logs or other information and be able to categorise accordingly, but skipped commits will inevitably end in inconclusive results.

##### Can this run any faster?

These scripts use `git bisect` which itself traverses, via binary search, the commit space (DAG) and as such is already efficient. Reducing the duration of the test under investigation is an option, but please see the caveats mentioned under `Required arguments... / experimental`

##### Can this help in finding the root cause of a gradual decline in performance?

Probably not; this is best used for when there is a distinct drop in performance at a point in time.

##### What happens if the bisection process is interrupted by something?

In the case of any outside interruptions which result in termination of the script, you can simply re-execute the command used to launch the bisection.

State is stored in the `config.json` which contains the results of all the runs of each traversed hash. Replaying/re-executing the script will always look here first and skip the build/run phase of any commit that has its results saved already.

A side effect of this is that you can manually update the `config.json` to manually classify hashes.

##### I've realised that a currently running hash is going to be good/bad, and don't want to wait for it to finish

Good news. You can CTRL^C, which will invoke the trap handler and prompt you on what to do next.

##### Even though I've set count to 5, there is only 1 (or some number < 5) runs happening at a time.

You are probably hitting the CPU quota in the project. Search `cpu-quota` in [bisect-util.sh](bisect-util.sh) and increase the value.


# Other

### `--first-parent`
This is an option that can be passed to `git bisect` (and is commented in the runner script), 
which instructs the process to only follow the `first parent` when encountering a merge commit. Essentially, this will 
result in bisect identifying which merge commit a regression was introduced in, but will not test any of the other parents. 
