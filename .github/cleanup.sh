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
    while read -r id tags; do
      [[ -n "${id}" ]] || continue
      if [[ "${DRY_RUN}" == "true" ]]; then
        echo "would delete ${package} ${id} ${tags}"
        deleted=$((deleted + 1))
        continue
      fi
      if ! can_request; then
        stopped="${package} at page ${page}"
        return
      fi
      budget=$((budget - 1))
      if gh_api --silent -X DELETE "${api}/${id}"; then
        echo "deleted ${package} ${id} ${tags}"
        deleted=$((deleted + 1))
        page_deleted=$((page_deleted + 1))
      else
        echo "::warning::failed to delete ${package} ${id} ${tags}"
        failed=$((failed + 1))
      fi
    done <<< "${selected}"

    # deleted versions made room for later ones, read this page again
    if ((page_deleted == 0)); then
      page=$((page + 1))
    fi
  done
}

deleted=0
failed=0
stopped=""
# starts with another package every hour, so a backlog in one package doesn't
# hold up the others
read -r -a packages <<< "${PACKAGES}"
offset=$((10#$(date -u +%H) % ${#packages[@]}))
for ((i = 0; i < ${#packages[@]}; i++)); do
  package="${packages[$(((offset + i) % ${#packages[@]}))]}"
  cleanup_package "${package}"
  if [[ -n "${stopped}" ]]; then
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
  echo "${deleted} versions deleted, ${failed} failed" | tee -a "${summary}"
fi
if ((failed > 0)); then
  echo "::error::${failed} versions could not be deleted"
  exit 1
fi
