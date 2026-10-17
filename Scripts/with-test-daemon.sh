#!/bin/sh
# Runs a command against a Paseo daemon: the one in PASEO_LIVE_URL if set, otherwise a throwaway one
# started here on 127.0.0.1:${PASEO_TEST_PORT:-6871} with its own home and one workspace, and stopped on
# exit. For a throwaway daemon it also sets PASEO_LIVE_WORKSPACE (that workspace), PASEO_LIVE_THROWAWAY=1
# and PASEO_LIVE_TERMINALS=1 (tests that change the daemon's state may run), and PASEO_LIVE_PLUGINS=1 once
# it has installed Scripts/test-plugin (tests of plugin UI may run). Every PASEO_LIVE_* variable
# (and PASEO_PASSWORD) is also exported as TEST_RUNNER_*, which xcodebuild hands to its test runners.
#
#   Scripts/with-test-daemon.sh swift test --filter Live
set -eu

if [ -z "${PASEO_LIVE_URL:-}" ]; then
  port=${PASEO_TEST_PORT:-6871}
  address=127.0.0.1:$port
  if curl -fsS "http://$address/api/health" >/dev/null 2>&1; then
    echo "Something already answers on $address; set PASEO_TEST_PORT or PASEO_LIVE_URL" >&2
    exit 1
  fi

  home=$(mktemp -d "${TMPDIR:-/tmp}/garbeo-test-daemon.XXXXXX")
  paseo daemon config set --home "$home" pluginsEnabled true >/dev/null
  echo "Starting a test daemon on $address (home: $home)" >&2
  PASEO_HOME=$home PASEO_LISTEN=$address PASEO_RELAY_ENABLED=false paseo daemon run --home "$home" >"$home/daemon.log" 2>&1 &
  pid=$!
  # shellcheck disable=SC2064
  trap "kill $pid 2>/dev/null; wait $pid 2>/dev/null; rm -rf '$home'" EXIT
  trap 'exit 130' INT TERM

  tries=0
  until curl -fsS "http://$address/api/health" >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [ $tries -gt 60 ] || ! kill -0 $pid 2>/dev/null; then
      echo "The test daemon didn't start:" >&2
      cat "$home/daemon.log" >&2
      exit 1
    fi
    sleep 1
  done

  # A workspace for tests that need one (terminals, tabs).
  project=$home/project
  mkdir -p "$project"
  git -C "$project" init -q -b main
  git -C "$project" -c user.name=Garbeo -c user.email=garbeo@example.invalid commit -q --allow-empty -m init
  # The health check can answer before the daemon accepts clients, so retry.
  workspace=
  tries=0
  while [ -z "$workspace" ]; do
    workspace=$(paseo workspace create --host "$address" --isolation local --path "$project" --title "Test project" --json 2>&1 |
      sed -n 's/.*"workspaceId": *"\([^"]*\)".*/\1/p')
    tries=$((tries + 1))
    if [ -z "$workspace" ]; then
      if [ $tries -ge 30 ]; then
        echo "Couldn't create a workspace on the test daemon:" >&2
        cat "$home/daemon.log" >&2
        exit 1
      fi
      sleep 1
    fi
  done

  # A plugin for tests of plugin UI: a workspace panel and workspace commands.
  plugin=$(cd "$(dirname "$0")" && pwd)/test-plugin
  paseo plugin install --host "$address" "$plugin" >/dev/null
  tries=0
  until paseo plugin ls --host "$address" --json 2>/dev/null | grep -q '"status": *"running"'; do
    tries=$((tries + 1))
    if [ $tries -ge 30 ]; then
      echo "The test plugin didn't start:" >&2
      paseo plugin ls --host "$address" >&2 || true
      exit 1
    fi
    sleep 1
  done

  export PASEO_LIVE_URL=$address
  export PASEO_LIVE_WORKSPACE=$workspace
  export PASEO_LIVE_THROWAWAY=1
  export PASEO_LIVE_TERMINALS=${PASEO_LIVE_TERMINALS:-1}
  export PASEO_LIVE_PLUGINS=1
fi

for name in $(env | sed -nE 's/^(PASEO_LIVE_[A-Z_]*|PASEO_PASSWORD)=.*/\1/p'); do
  eval "export TEST_RUNNER_$name=\"\$$name\""
done
"$@"
