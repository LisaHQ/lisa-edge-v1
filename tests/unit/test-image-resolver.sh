#!/usr/bin/env bash
set -euo pipefail

# Generic container-image release-tag resolver (lib/images.sh): Docker Hub
# pagination with bounded pages, GHCR token flow, release-tag filtering,
# offline behavior, unsupported registries, the disable seam, and floating
# reference classification. Network access is mocked by overriding
# lisa_image_fetch_url / lisa_image_fetch_url_auth.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
. "$REPO_ROOT/services/registry.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/lib/images.sh"

fail() {
  echo "IMAGE RESOLVER TEST ERROR: $*" >&2
  exit 1
}

OTBR_FILTER="$(lisa_service_image_tag_filter otbr)"
MATTER_FILTER="$(lisa_service_image_tag_filter matter)"

page() {
  local next="$1"
  shift
  local names="" name
  for name in "$@"; do
    names+="{\"name\": \"$name\"},"
  done
  printf '{"count": 999, "next": %s, "results": [%s]}' "$next" "${names%,}"
}

FETCH_LOG="$(mktemp "${TMPDIR:-/tmp}/image-fetch-log.XXXXXX")"
trap 'rm -f "$FETCH_LOG"' EXIT
lisa_image_fetch_url() {
  printf '%s\n' "$1" >> "$FETCH_LOG"
  case "$1" in
    *page=fail*) return 1 ;;
    *page=2*) printf '%s' "$MOCK_PAGE_2" ;;
    *page=3*) printf '%s' "$MOCK_PAGE_3" ;;
    https://ghcr.io/token*) printf '%s' "$MOCK_GHCR_TOKEN" ;;
    *) printf '%s' "$MOCK_PAGE_1" ;;
  esac
}
lisa_image_fetch_url_auth() {
  printf '%s auth=%s\n' "$1" "$2" >> "$FETCH_LOG"
  printf '%s' "$MOCK_GHCR_TAGS"
}

# --- release tag on the first Docker Hub page --------------------------------
MOCK_PAGE_1="$(page 'null' latest main v2026.06.0 v2026.07.1)"
result="$(lisa_image_query_release_tags openthread/border-router "$OTBR_FILTER")" ||
  fail "first-page resolution failed"
[ "$(head -n 1 <<<"$result")" = "v2026.07.1" ] ||
  fail "expected v2026.07.1 first from page 1, got: $result"

# --- release tag listing: newest first, unique -------------------------------
MOCK_PAGE_1="$(page 'null' latest v2026.06.0 v2026.07.1 v2026.06.0 v2026.05.2)"
tags="$(lisa_image_query_release_tags openthread/border-router "$OTBR_FILTER")" ||
  fail "release tag listing failed"
[ "$tags" = "$(printf 'v2026.07.1\nv2026.06.0\nv2026.05.2')" ] ||
  fail "release tags must be unique and newest first, got: $tags"

# --- release tags only on a later page ---------------------------------------
MOCK_PAGE_1="$(page '"https://hub.docker.com/v2/repositories/openthread/border-router/tags?page=2"' latest main sha-1234567)"
MOCK_PAGE_2="$(page '"https://hub.docker.com/v2/repositories/openthread/border-router/tags?page=3"' nightly sha-89abcde)"
MOCK_PAGE_3="$(page 'null' v2026.05.0 v2026.07.0)"
: > "$FETCH_LOG"
result="$(lisa_image_query_release_tags openthread/border-router "$OTBR_FILTER")" ||
  fail "multi-page resolution failed"
[ "$(head -n 1 <<<"$result")" = "v2026.07.0" ] ||
  fail "expected v2026.07.0 from page 3, got: $result"
[ "$(grep -c . "$FETCH_LOG")" -eq 3 ] || fail "expected exactly 3 page fetches"

# --- pagination limit is bounded ---------------------------------------------
MOCK_PAGE_1="$(page '"https://hub.docker.com/v2/repositories/openthread/border-router/tags?page=2"' latest)"
MOCK_PAGE_2="$(page '"https://hub.docker.com/v2/repositories/openthread/border-router/tags?page=2"' main)"
: > "$FETCH_LOG"
if LISA_IMAGE_QUERY_MAX_PAGES=3 \
  lisa_image_query_release_tags openthread/border-router "$OTBR_FILTER" >/dev/null; then
  fail "an endless tag list without releases must fail"
fi
[ "$(grep -c . "$FETCH_LOG")" -eq 3 ] ||
  fail "pagination must stop at LISA_IMAGE_QUERY_MAX_PAGES"

# --- no release tag anywhere -------------------------------------------------
MOCK_PAGE_1="$(page 'null' latest main sha-1234567)"
if lisa_image_query_release_tags openthread/border-router "$OTBR_FILTER" >/dev/null; then
  fail "a tag list without release tags must fail"
fi

# --- offline / fetch failure -------------------------------------------------
MOCK_PAGE_1="$(page '"https://hub.docker.com/v2/repositories/openthread/border-router/tags?page=fail"' latest)"
if lisa_image_query_release_tags openthread/border-router "$OTBR_FILTER" >/dev/null; then
  fail "a failing page fetch must fail the resolution"
fi

# --- hostile next URLs are not followed --------------------------------------
MOCK_PAGE_1="$(page '"https://evil.example.com/tags?page=2"' latest v2026.01.1)"
: > "$FETCH_LOG"
result="$(lisa_image_query_release_tags openthread/border-router "$OTBR_FILTER")" ||
  fail "resolution with hostile next URL failed"
[ "$(head -n 1 <<<"$result")" = "v2026.01.1" ] || fail "unexpected result: $result"
[ "$(grep -c . "$FETCH_LOG")" -eq 1 ] || fail "non-dockerhub next URLs must not be fetched"

# --- official Docker Hub images resolve under library/ -----------------------
MOCK_PAGE_1="$(page 'null' 2 2.0.22 2.0.21 openssl)"
: > "$FETCH_LOG"
result="$(lisa_image_query_release_tags eclipse-mosquitto "$(lisa_service_image_tag_filter mqtt)")" ||
  fail "official image resolution failed"
grep -q 'repositories/library/eclipse-mosquitto/' "$FETCH_LOG" ||
  fail "official images must be queried under library/"
[ "$(head -n 1 <<<"$result")" = "2.0.22" ] || fail "unexpected mosquitto tag: $result"
grep -qx 'openssl' <<<"$result" && fail "non-release variant tags must be filtered out"

# --- GHCR: anonymous token flow, filtered, alpha/dev excluded ----------------
MOCK_GHCR_TOKEN='{"token": "test-token-value"}'
MOCK_GHCR_TAGS='{"name":"matter-js/matterjs-server","tags":["1.2.0","1.3.0","1.3.1","stable","main","1.4.0-alpha.1"]}'
: > "$FETCH_LOG"
result="$(lisa_image_query_release_tags ghcr.io/matter-js/matterjs-server "$MATTER_FILTER")" ||
  fail "GHCR resolution failed"
[ "$(head -n 1 <<<"$result")" = "1.3.1" ] || fail "expected 1.3.1 newest, got: $result"
grep -qx 'stable' <<<"$result" && fail "floating GHCR tags must be filtered out"
grep -qx '1.4.0-alpha.1' <<<"$result" && fail "alpha GHCR tags must be filtered out"
grep -q 'auth=test-token-value' "$FETCH_LOG" ||
  fail "the GHCR tag list must be fetched with the anonymous pull token"

# --- unsupported third-party registries fail gracefully ----------------------
if lisa_image_query_release_tags registry.local/team/image '^v' >/dev/null; then
  fail "unsupported registries must fail (graceful local-only fallback)"
fi

# --- the disable seam turns discovery off ------------------------------------
: > "$FETCH_LOG"
MOCK_PAGE_1="$(page 'null' v2026.07.1)"
if LISA_IMAGE_QUERY_DISABLE=1 \
  lisa_image_query_release_tags openthread/border-router "$OTBR_FILTER" >/dev/null; then
  fail "LISA_IMAGE_QUERY_DISABLE=1 must fail the resolution"
fi
[ "$(grep -c . "$FETCH_LOG" || true)" -eq 0 ] ||
  fail "LISA_IMAGE_QUERY_DISABLE=1 must not fetch anything"

# --- floating reference classification ---------------------------------------
lisa_image_ref_is_floating "openthread/border-router:latest" || fail "latest must be floating"
lisa_image_ref_is_floating "openthread/border-router" || fail "an untagged reference must be floating"
lisa_image_ref_is_floating "ghcr.io/matter-js/matterjs-server:stable" || fail "stable must be floating"
if lisa_image_ref_is_floating "openthread/border-router:v2026.07.0"; then
  fail "release tags must not be floating"
fi
if lisa_image_ref_is_floating "eclipse-mosquitto:2"; then
  fail "a numeric major tag must not be classified as floating"
fi
if lisa_image_ref_is_floating "openthread/border-router@sha256:$(printf '1%.0s' $(seq 1 64))"; then
  fail "digest-pinned images must not be floating"
fi
if lisa_image_ref_is_floating "registry.local:5000/otbr:v1.0.0"; then
  fail "a registry with a port must not confuse tag detection"
fi

echo "Image resolver tests passed."
