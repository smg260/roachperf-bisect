Set of bash scripts to help bisect a roach perf regression.

At a high level:
- user specifies a date range or good and bad commit hashes
- if starting good/bad thresholds are not specified, both good and bad hashes are run via roachteset to collect a baseline
- git bisect is used to progress through hashes
- each hash is built and run via roachtest with its end metric parsed
- the metric is used to determine if hash will then be marked good/bad/skipped/<prompt for user input>
- each hash metric and existing good/bad thresholds are stored in a config json
- subsequent runs or replays of the bisect will look in the config.json first 
