This repository houses a set of bash scripts to help bisect a roach perf regression.

At a high level:

- `bisect_runner.sh` is the executable entry point
- user specifies args (see section below) in `bisect_runner.sh`
- if starting good/bad thresholds are not specified in the `config.json`, both good and bad hashes are run via roachteset to collect a baseline
- `git bisect` is used to progress through hashes
- each chosen hash is built and run via roachtest with the result stored in the `config.json`
- the median or average of that result is used to determine if hash will then be marked good/bad/skipped/prompt for user input.
- eventually git bisect will arrive at a potential culprit commit
- subsequent runs or replays of the bisect will look in the config.json first

Note: the script will prompt the user for good/bad/skip/quit if a collected metric falls between the good and bad thresholds. If a user marks it as good or bad, the relevant threshold will be updated for future hashes.

# Prerequisites

1. bash/zsh
2. jq
3. you can build cockroach/roachtest/roachprod on the machine

# Running a bisection

`git clone` this repository, and execute `bisect_runner.sh` from the cockroach root. Specify arguments below.

1. git clone this
2. edit `bisect_runner.sh` to update arguments
3. `~/go/src/github.com/cockroachdb/cockroach`
4. `./path_to_this_repo/bisect_runner.sh`

Using a gce worker is highly recommended.


# Required arguments for `bisect_runner.sh`

`bisect_runner.sh` is the entry point and where the following parameter values should be defined

`test` a single roach test e.g. `kv0/enc=false/nodes=3/batch=16`

`cloud` cloud that the test runs on. Can be one of `gce,aws`

`branch` the git branch e.g. `origin/master`

`count` number of concurrent runs from which to collect a comparable metric e.g. `4`

`metric` which metric to use for comparison. Can be one of `median,average`

`goodHash` the hash of the last known good commit. See notes below to determine the good and bad hash.

`bashHash` the hash of the first known bad commit. See notes below to determine the good and bad hash.

*experimental*

`duration_mins` overrides the number of minutes a test runs for. Currently only `kv*` and `ycsb*` tests supported. N.B. use this with discretion. It patches the source file of the roachtest before building.

*optional*

`BISECT_DIR` where log files and config.json are stored. e.g. `/home/<user>/bisections/issues/97790` Default: cwd

### Finding the appropriate good and bad hashes

Note the date on the roachperf dashboard where the regression was first observed. This date has a corresponding TeamCity nightly roachtest run, from which we can extract the `badHash`. Repeat for the previous date (where the metric is good), and you will have a `goodHash`


# The config.json and specifying good/bad thresholds

The config json file is where all the results for roachtest runs for various benchmarks are stored. [Sample config.json](./sample_config.json) It is also used for a degree of resiliency should the script fail for any reason. You can simply re-run the script, which will look in the config.json first for any results before attempting to execute a roachtest.

As bisection progresses, the scripts will update and add entries to this file. An array of results is stored for every hash that is run. e.g. if `count=5`, you will see 5 numbers per hash corresponding to each run.

As previously mentioned, when a good/bad hash is specified, the script will attempt to build/run both hashes to collect baseline before commencing the bisect. However, if you would like to specify reasonable thresholds beforehand, add the corresponding numbers for each of the good and bad hash in the config.json.

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

# Logging

Logs are created for the build/running of each hash.

The 2 main informational logs are

`info.log` shows progress of the bisection and will ultimately look something like

```plaintext
2023-02-28T16:59:44Z   Bisecting regression in [kv0/enc=false/nodes=3/batch=16] using commit range [44d9f3c8b7b (known good),5fbcd8a8dea (known bad)]
2023-02-28T16:59:44Z   Thresholds [good >= 1297, bad <= 1133]
2023-02-28T17:17:15Z   [1708ea4b2a2] median ops/s: [1144]. User marked as bad. Threshold updated.
2023-02-28T17:33:48Z   [ca70b824690] median ops/s: [1281]. User marked as good. Threshold updated.
2023-02-28T17:54:10Z   [ebc33fa0823] median ops/s: [1096]. Auto marked as bad.
2023-02-28T18:11:33Z   [c18156317dd] median ops/s: [1099]. Auto marked as bad.
2023-02-28T18:28:54Z   [702ff6fa87c] median ops/s: [1080]. Auto marked as bad.
2023-02-28T18:28:54Z   Bisection complete. Suspect commit:
commit 702ff6fa87c7494b240a16303ecf3e2a37c18e48
Author: Some User <someuser@gmail.com>
Date:   Thu Dec 22 13:23:57 2022 -0500

    kv: some commit description
```

`bisect.log` is the log created by `git bisect` and can be used to tweak/replay a bisect. See git documentation.

# Limitations

- Some roachperf graphs are noisy and and will be inherently difficult to bisect looking at just performance numbers. This can be mitigated by having as many concurrent runs as possible (>= 5). Even then, some bisections where results are borderline good or bad may arrive at an incorrect culprit commit.
- Only works for YCSB and KV benchmarks for now.
- Requires the good metric to be "higher" and the bad metric "lower". Easily changed but that is the assumption for now.
- Script trap handling is not bulletproof and as such if you kill the script early, it *may* not terminate the child processes.
