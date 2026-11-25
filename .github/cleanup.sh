#!/bin/bash

# Deletes old versions of the cache packages ghcr.io/<owner>/<package> in
# PACKAGES (space separated):
# - versions whose tags all match HANDOFF_TAGS (a jq regex, empty for none)
#   after MAX_AGE hours, like the handoff caches of containerbase/base, which
#   are only read in the same workflow run.
# - untagged versions, caches whose tag was overwritten by a newer push, after
#   MAX_UNTAGGED_AGE days.
# Other tagged versions are never touched. The packages share the request
# budget of a run.
#
# The api lists the newest versions first. This walks the pages from the
# first one: deep pages fail with a server error on large packages. Deleting
# versions on a page moves the versions of the later pages forward, so a page
# with deletes is read again, until a read deletes nothing. The order isn't
# documented, so it reads every page rather than stopping at the first page
# without old versions. It stops when the request budget or the time of this
# run is used up; the next run starts at the first page again.
#
# PARALLEL deletes run at the same time. A delete that fails is checked: if
# the version is gone, it counts as deleted. A delete that fails with a server
# error or a timeout is left to the next run, with a warning; a secondary rate
# limit stops the run, the next run continues; other errors, like a missing
# admin role, fail the run.
#
# Usage: cleanup.sh, configured by the environment variables below.

set -euo pipefail

: "${ORG:?}" "${PACKAGES:?}"
DRY_RUN="${DRY_RUN:-false}"
MAX_AGE="${MAX_AGE:-24}"
MAX_UNTAGGED_AGE="${MAX_UNTAGGED_AGE:-7}"
HANDOFF_TAGS="${HANDOFF_TAGS:-}"
# requests of the hourly api limit to leave for other workflows
RESERVE="${RESERVE:-100}"
# in seconds, stop before the job timeout
MAX_DURATION="${MAX_DURATION:-2700}"
# in seconds, for a single api request
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-60}"
# page reads per package, 0 for no limit; the dry run in pull requests reads
# only a few to leave the budget to the cleanup
MAX_PAGES="${MAX_PAGES:-0}"
# deletes at the same time. A delete counts 5 points of the secondary rate
# limit of 900 points a minute, so at most 180 deletes a minute; a delete takes
# about a second.
PARALLEL="${PARALLEL:-2}"

cutoff="$(date -u -d "-${MAX_AGE} hours" +%Y-%m-%dT%H:%M:%SZ)"
untagged_cutoff="$(date -u -d "-${MAX_UNTAGGED_AGE} days" +%Y-%m-%dT%H:%M:%SZ)"

# runs gh with a time limit, so a hanging request can't use up the run
gh_api() {
  timeout "${REQUEST_TIMEOUT}" gh api "$@"
}

# reads from the api into `response`, retrying failed requests like server
# errors; every attempt counts against the budget. Not run in a subshell, so
# the budget is kept.
gh_get() {
  local attempt
  for attempt in 1 2 3; do
    budget=$((budget - 1))
    if response="$(gh_api "$@")"; then
      return 0
    fi
    if ((attempt == 3)) || ! can_request; then
      return 1
    fi
    echo "request failed, retrying in $((attempt * 10))s" >&2
    sleep $((attempt * 10))
  done
}

# whether this run may send another request
can_request() {
  ((budget > 0 && SECONDS < MAX_DURATION))
}

# deletes a version, `error_file` takes gh's error. If that fails, sets
# `delete_error` to gh's error and the request id of the response,
# `delete_gone` if the version is gone anyway, as after some server errors,
# `delete_retry` if the next run should try again, and `delete_limit` on a
# secondary rate limit. `delete_requests` is the number of requests it sent.
delete_version() {
  local url="$1" error_file="$2" status=0 headers check request_id
  delete_gone=0
  delete_retry=0
  delete_limit=0
  delete_requests=1
  headers="$(gh_api --include -X DELETE "${url}" 2> "${error_file}")" || status=$?
  if ((status == 0)); then
    return 0
  fi
  if ((status == 124)); then
    delete_error="no response within ${REQUEST_TIMEOUT}s"
  else
    delete_error="$(tr -s '[:space:]' ' ' < "${error_file}" | cut -c 1-300)"
    request_id="$(sed -n 's/^x-github-request-id: *\([^[:space:]]*\).*/\1/Ip' <<< "${headers}" | head -n 1)"
    if [[ -n "${request_id}" ]]; then
      delete_error="${delete_error% }, request ${request_id}"
    fi
  fi
  if [[ "${delete_error}" =~ HTTP\ 404 ]]; then
    delete_gone=1
    return 1
  fi
  if [[ "${delete_error}" =~ (secondary\ rate\ limit|HTTP\ 429) ]]; then
    delete_limit=1
    return 1
  fi
  if ((status == 124)) || [[ "${delete_error}" =~ HTTP\ 5[0-9][0-9] ]]; then
    delete_retry=1
    # the version may be deleted despite the error. The budget for this check
    # is reserved with the delete, see `cleanup_package`.
    if ((SECONDS < MAX_DURATION)); then
      delete_requests=2
      if ! check="$(gh_api --silent "${url}" 2>&1)"; then
        if [[ "${check}" =~ HTTP\ 404 ]]; then
          delete_gone=1
        elif [[ "${check}" =~ (secondary\ rate\ limit|HTTP\ 429) ]]; then
          delete_limit=1
        fi
      fi
    fi
  fi
  return 1
}

# deletes a version in the background, writes `<result> <requests> <error>`
# to `<folder>/<id>.result`, with the result `ok`, `gone`, `retry`, `limit` or
# `fail`
delete_job() {
  local url="$1" id="$2" dir="$3" result=fail
  delete_error=""
  if delete_version "${url}" "${dir}/${id}.err"; then
    result=ok
  elif ((delete_gone)); then
    result=gone
  elif ((delete_limit)); then
    result=limit
  elif ((delete_retry)); then
    result=retry
  fi
  echo "${result} ${delete_requests} ${delete_error}" > "${dir}/${id}.result.tmp"
  # complete files only, `must_stop` reads them while others still run
  mv "${dir}/${id}.result.tmp" "${dir}/${id}.result"
}

# whether a finished delete of this page hit a rate limit or failed, so no
# further deletes should start
must_stop() {
  grep -qsE '^(limit|fail) ' "${jobs_dir}"/*.result
}

# result files of the deletes of a page
jobs_dir="$(mktemp -d)"
trap 'rm -rf "${jobs_dir}"' EXIT

# requests left of this run, from the remaining hourly limit of the token,
# checking it doesn't count against the limit
budget="$(gh_api /rate_limit --jq '.resources.core.remaining')"
budget=$((budget - RESERVE))
if [[ -n "${HANDOFF_TAGS}" ]]; then
  echo "deleting tags matching ${HANDOFF_TAGS} before ${cutoff}"
fi
echo "deleting untagged versions before ${untagged_cutoff}, budget ${budget} requests"

# cleans up one package, sets `stopped` to where it stopped when the budget or
# time ran out
cleanup_package() {
  local package="$1"
  local api="/orgs/${ORG}/packages/container/${package}/versions"
  local versions selected id tags

  local page=1 page_deleted reads=0
  while true; do
    if ((MAX_PAGES > 0 && reads >= MAX_PAGES)); then
      echo "${package}: read ${reads} pages, the limit"
      return
    fi
    reads=$((reads + 1))
    if ! can_request; then
      stopped="${package} at page ${page}"
      return
    fi
    if ! gh_get "${api}?per_page=100&page=${page}"; then
      echo "::error::failed to read page ${page} of ${package}"
      exit 1
    fi
    versions="${response}"
    if jq -e 'length == 0' <<< "${versions}" > /dev/null; then
      echo "${package}: done after ${page} pages"
      return
    fi

    # in a variable, so a jq error fails the run
    selected="$(jq -r --arg cutoff "${cutoff}" --arg untagged_cutoff "${untagged_cutoff}" --arg handoff "${HANDOFF_TAGS}" '
      .[]
      | .metadata.container.tags as $tags
      | select(
          ($handoff != ""
            and ($tags | length) > 0
            and .updated_at < $cutoff
            and all($tags[]; test($handoff)))
          or (($tags | length) == 0 and .updated_at < $untagged_cutoff)
        )
      | "\(.id) \(if ($tags | length) > 0 then ($tags | join(",")) else "<untagged>" end)"
    ' <<< "${versions}")"

    page_deleted=0
    local started=() result requests error
    rm -f "${jobs_dir}"/*
    while read -r id tags; do
      [[ -n "${id}" ]] || continue
      # failed in this run already, left for the next run
      [[ -z "${postponed_ids[${id}]:-}" ]] || continue
      if [[ "${DRY_RUN}" == "true" ]]; then
        echo "would delete ${package} ${id} ${tags}"
        deleted=$((deleted + 1))
        continue
      fi
      # room for the delete and a check after an error
      if ((budget < 2)) || ! can_request; then
        stopped="${package} at page ${page}"
        break
      fi
      while (($(jobs -rp | wc -l) >= PARALLEL)); do
        wait -n || true
      done
      # a finished delete hit a rate limit or failed, the results below say
      # which
      if must_stop; then
        break
      fi
      # reserves the check too, the results give back what wasn't used
      budget=$((budget - 2))
      delete_job "${api}/${id}" "${id}" "${jobs_dir}" &
      started+=("${id} ${tags}")
    done <<< "${selected}"
    wait || true

    # the results in the order of the page
    for entry in "${started[@]}"; do
      read -r id tags <<< "${entry}"
      read -r result requests error < "${jobs_dir}/${id}.result"
      budget=$((budget + 2 - requests))
      case "${result}" in
        ok)
          echo "deleted ${package} ${id} ${tags}"
          deleted=$((deleted + 1))
          page_deleted=$((page_deleted + 1))
          ;;
        gone)
          echo "deleted ${package} ${id} ${tags}, though the delete answered: ${error}"
          deleted=$((deleted + 1))
          page_deleted=$((page_deleted + 1))
          ;;
        retry)
          echo "::warning::could not delete ${package} ${id} ${tags}, the next run retries: ${error}"
          postponed=$((postponed + 1))
          postponed_ids[${id}]=1
          ;;
        limit)
          echo "::warning::could not delete ${package} ${id} ${tags}, rate limited: ${error}"
          postponed=$((postponed + 1))
          postponed_ids[${id}]=1
          stopped="${package} at page ${page}, rate limited"
          ;;
        *)
          # like a missing admin role, the other deletes would fail as well
          echo "::error::failed to delete ${package} ${id} ${tags}: ${error}"
          failed=$((failed + 1))
          ;;
      esac
    done
    if [[ -n "${stopped}" ]] || ((failed > 0)); then
      return
    fi

    # deleted versions made room for later ones, read this page again
    if ((page_deleted == 0)); then
      page=$((page + 1))
    fi
  done
}

deleted=0
postponed=0
declare -A postponed_ids=()
failed=0
stopped=""
# starts with another package every hour, so a backlog in one package doesn't
# hold up the others
read -r -a packages <<< "${PACKAGES}"
offset=$((10#$(date -u +%H) % ${#packages[@]}))
for ((i = 0; i < ${#packages[@]}; i++)); do
  package="${packages[$(((offset + i) % ${#packages[@]}))]}"
  cleanup_package "${package}"
  if [[ -n "${stopped}" ]] || ((failed > 0)); then
    break
  fi
done

summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
if [[ -n "${stopped}" ]]; then
  echo "::notice::stopped in ${stopped}, the next run continues (budget ${budget}, ${SECONDS}s)"
  echo "stopped in ${stopped}, the next run continues" >> "${summary}"
fi
if [[ "${DRY_RUN}" == "true" ]]; then
  echo "${deleted} versions would be deleted" | tee -a "${summary}"
else
  echo "${deleted} versions deleted, ${postponed} left for the next run, ${failed} failed" | tee -a "${summary}"
fi
if ((postponed > 0)); then
  echo "::warning::${postponed} versions could not be deleted because of server errors or rate limits, the next run retries them"
fi
if ((failed > 0)); then
  echo "::error::${failed} versions could not be deleted"
  exit 1
fi
