#!/usr/bin/env bash
# shellcheck shell=bash
# BREW_REVIEWED_PROBE_V1
# A separate job-control shell owns the probe and timer process groups.
set -u
set -m

probe_pid=""
timer_pid=""
cancel_status=0
trap 'if (( cancel_status == 0 || cancel_status == 124 )); then cancel_status=130; fi' INT
trap 'if (( cancel_status == 0 || cancel_status == 124 )); then cancel_status=143; fi' TERM
trap 'if (( cancel_status == 0 )); then cancel_status=124; fi' USR1

finish_probe() {
  local status="$1"
  trap '' INT TERM USR1
  if [[ -n "$timer_pid" ]]; then
    kill -KILL -- "-$timer_pid" 2>/dev/null || :
    wait "$timer_pid" 2>/dev/null || :
  fi
  if [[ -n "$probe_pid" ]] && kill -0 -- "-$probe_pid" 2>/dev/null; then
    if (( status == 0 )); then
      printf '%s\n' 'Probe left running descendants; refusing success.' >&2
      status=1
    fi
    kill -TERM -- "-$probe_pid" 2>/dev/null || :
    sleep 1
    kill -KILL -- "-$probe_pid" 2>/dev/null || :
  fi
  if [[ -n "$probe_pid" ]]; then
    wait "$probe_pid" 2>/dev/null || :
  fi
  if (( status == 124 )); then
    printf '%s\n' 'Probe timed out after 10 seconds (up to 1 second termination grace).' >&2
  fi
  exit "$status"
}

if (( $# == 0 )); then exit 2; fi
if (( cancel_status )); then finish_probe "$cancel_status"; fi
(set +m; exec "$@") </dev/null &
probe_pid=$!
# Trap handlers only record cancellation until both launch PIDs are published.
(set +m; sleep 10; kill -USR1 "$$") &
timer_pid=$!
if (( cancel_status )); then finish_probe "$cancel_status"; fi
if wait "$probe_pid"; then probe_status=0; else probe_status=$?; fi
if (( cancel_status )); then probe_status=$cancel_status; fi
finish_probe "$probe_status"
