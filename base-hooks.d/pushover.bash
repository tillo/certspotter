#!/bin/bash

# shellcheck disable=SC1091
source /certspotter/utils.bash

# Never-before-seen filter (2026-07-13): only page for certificates that
# contain a DNS name we have never observed before, or that were issued
# by a non-Let's-Encrypt CA. Routine LE renewals of known names are the
# bulk of CT-log traffic for this watchlist and carry no signal — they
# are logged to stdout but not pushed.
#
# State: newline-sorted SAN list on the PVC, seeded once from the
# historical .certspotter/certs store. If the seed file is absent the
# filter is INACTIVE and every event notifies (old behavior, fail-open).
SEEN_FILE=/certspotter/.certspotter/seen_sans.txt
LOCK_FILE=/certspotter/.certspotter/seen_sans.lock

if [ -n "${1}" ]; then
  SUMMARY=$1
fi

NOTIFY=1
REASON=""

if [ -n "${TEXT_FILENAME}" ] && [ -f "${TEXT_FILENAME}" ]; then
  TEXT=$(<"${TEXT_FILENAME}")
  SUMMARY="${SUMMARY}
${TEXT}"

  mapfile -t NAMES < <(grep -oP '(?<=DNS Name = ).+' "${TEXT_FILENAME}" | sort -u)
  ISSUER=$(grep -m1 -oP '(?<=Issuer = ).+' "${TEXT_FILENAME}")

  if [ "${#NAMES[@]}" -gt 0 ] && [ -f "${SEEN_FILE}" ]; then
    NEW_NAMES=()
    for n in "${NAMES[@]}"; do
      grep -qxF "$n" "${SEEN_FILE}" || NEW_NAMES+=("$n")
    done

    # Record every name (new ones included) under a lock — certspotter
    # monitors many CT logs and can fire hooks concurrently.
    (
      flock 9
      printf '%s\n' "${NAMES[@]}" >>"${SEEN_FILE}"
      sort -u -o "${SEEN_FILE}" "${SEEN_FILE}"
    ) 9>"${LOCK_FILE}"

    if [ "${#NEW_NAMES[@]}" -gt 0 ]; then
      REASON="⚠️ never-seen name(s): ${NEW_NAMES[*]}"
    elif [[ "${ISSUER}" != *"O=Let's Encrypt"* ]]; then
      REASON="⚠️ non-LE issuer: ${ISSUER}"
    else
      NOTIFY=0
      info "suppressed: known-SAN Let's Encrypt renewal (${NAMES[*]})"
    fi
  fi
fi
# Non-cert events (error / malformed — no TEXT with DNS names) always notify.

if [ "${NOTIFY}" -eq 1 ] && [ -n "${SUMMARY}" ] && [ -n "${CS_PUSHOVER_TOKEN}" ] && [ -n "${CS_PUSHOVER_USER}" ]; then
  if [ -n "${REASON}" ]; then
    SUMMARY="${REASON}
${SUMMARY}"
  fi
  # Form-encoded, NOT hand-built JSON: cert text contains quotes and
  # newlines, which broke the JSON body (invalid JSON string) and made
  # Pushover reject multiline messages silently (curl --silent, response
  # discarded). Message capped at Pushover's 1024-char limit.
  curl -X POST --silent \
    --form-string "token=${CS_PUSHOVER_TOKEN}" \
    --form-string "user=${CS_PUSHOVER_USER}" \
    --form-string "title=certspotter" \
    --form-string "message=${SUMMARY:0:1000}" \
    "https://api.pushover.net/1/messages.json"
fi
