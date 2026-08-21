#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <uvm-log>" >&2
  exit 2
fi

readonly log_file=$1
if [[ ! -r "$log_file" ]]; then
  echo "UVM summary log is not readable: $log_file" >&2
  exit 2
fi

awk '
  BEGIN {
    summary_count = 0
    in_summary = 0
    warning_seen = 0
    error_seen = 0
    fatal_seen = 0
    malformed = 0
  }
  {
    sub(/\r$/, "")
  }
  $0 == "--- UVM Report Summary ---" {
    summary_count++
    in_summary = 1
    next
  }
  in_summary && /^\*\* Report counts by id/ {
    in_summary = 0
    next
  }
  in_summary && $1 == "UVM_WARNING" && $2 == ":" {
    warning_seen++
    if ($3 !~ /^[0-9]+$/)
      malformed = 1
    else
      warning_count = $3 + 0
    next
  }
  in_summary && $1 == "UVM_ERROR" && $2 == ":" {
    error_seen++
    if ($3 !~ /^[0-9]+$/)
      malformed = 1
    else
      error_count = $3 + 0
    next
  }
  in_summary && $1 == "UVM_FATAL" && $2 == ":" {
    fatal_seen++
    if ($3 !~ /^[0-9]+$/)
      malformed = 1
    else
      fatal_count = $3 + 0
    next
  }
  END {
    if (summary_count != 1) {
      printf "expected exactly one UVM report summary, found %d\n", \
             summary_count > "/dev/stderr"
      exit 2
    }
    if (warning_seen != 1 || error_seen != 1 || fatal_seen != 1 ||
        malformed) {
      print "UVM report summary is missing or has malformed severity counts" \
        > "/dev/stderr"
      exit 2
    }
    if (warning_count != 0 || error_count != 0 || fatal_count != 0) {
      printf "UVM report is not pristine: warning=%d error=%d fatal=%d\n", \
             warning_count, error_count, fatal_count > "/dev/stderr"
      exit 1
    }
    printf "UVM report is pristine: warning=0 error=0 fatal=0\n"
  }
' "$log_file"
