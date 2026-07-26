#!/usr/bin/env bash
set -euo pipefail

# Git-managed image advisory catalog and the generic interactive image
# selection (lib/images.sh): TSV parsing, comments, malformed rows, unknown
# service keys, unsupported statuses, exact reference matching, menu
# formatting, known-issue confirmation, blocked rejection, custom image
# input, and offline fallback. No network: discovery is mocked.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
. "$REPO_ROOT/services/registry.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/lib/images.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/install/provisioning/lib/ui.sh"

fail() {
  echo "IMAGE ADVISORY TEST ERROR: $*" >&2
  exit 1
}

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/image-advisory-test.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

# --- the shipped catalog is valid and carries the seed record ----------------
lisa_image_advisories_validate "$REPO_ROOT/services/image-advisories.tsv" ||
  fail "the shipped services/image-advisories.tsv must validate"
entry="$(LISA_IMAGE_ADVISORY_FILE="$REPO_ROOT/services/image-advisories.tsv" \
  lisa_image_advisory_lookup matter "ghcr.io/matter-js/matterjs-server:1.3.1")" ||
  fail "the seeded matterjs-server 1.3.1 advisory must be found"
[ "${entry%%$'\t'*}" = "known-issue" ] ||
  fail "the seeded advisory must have status known-issue, got: $entry"
grep -q 'BLE commissioning regression' <<<"$entry" ||
  fail "the seeded advisory note must be returned"

# --- parsing: comments, blank lines, exact matching --------------------------
CATALOG="$WORK_DIR/advisories.tsv"
printf '# comment line\n\nmatter\tghcr.io/matter-js/matterjs-server:1.3.1\tknown-issue\tBLE regression\notbr\topenthread/border-router:v2026.05.0\tblocked\tRadio startup failure observed by LISA Edge\n' > "$CATALOG"
export LISA_IMAGE_ADVISORY_FILE="$CATALOG"

lisa_image_advisories_validate "$CATALOG" || fail "a well-formed catalog must validate"
lisa_image_advisory_lookup matter "ghcr.io/matter-js/matterjs-server:1.3.1" >/dev/null ||
  fail "an exact match must be found"
if lisa_image_advisory_lookup matter "ghcr.io/matter-js/matterjs-server:1.3.10" >/dev/null; then
  fail "matching must be exact: 1.3.10 must not match the 1.3.1 record"
fi
if lisa_image_advisory_lookup otbr "ghcr.io/matter-js/matterjs-server:1.3.1" >/dev/null; then
  fail "matching must be per-service, not per-image only"
fi
[ "$(lisa_image_advisory_images_for_service otbr)" = "openthread/border-router:v2026.05.0" ] ||
  fail "cataloged images for a service must be listable"

# --- malformed catalogs are rejected ----------------------------------------
bad() {
  local content="$1" reason="$2" out rc=0
  printf '%b' "$content" > "$WORK_DIR/bad.tsv"
  out="$(lisa_image_advisories_validate "$WORK_DIR/bad.tsv" 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "malformed catalog must be rejected ($reason)"
}
bad 'matter\tghcr.io/x:1\tknown-issue\n' "missing note field"
bad 'matter\tghcr.io/x:1\tknown-issue\tnote\textra\n' "extra field (embedded tab)"
bad 'not-a-service\tghcr.io/x:1\tknown-issue\tnote\n' "unknown service key"
bad 'matter\tghcr.io/x:1\tuntested\tnote\n' "unsupported status"
bad 'matter\tghcr.io/x:1\tpassed\tnote\n' "positive statuses are not supported"
bad 'matter\tghcr.io/x:1\tknown-issue\t\n' "empty note"
bad 'matter\tghcr.io/x 1\tknown-issue\tnote\n' "space in image reference"
bad 'matter\tghcr.io/x:1\tknown-issue\tnote\r\n' "carriage return"

# --- menu line formatting -----------------------------------------------------
line="$(lisa_image_menu_line matter "ghcr.io/matter-js/matterjs-server:1.3.0" \
  "ghcr.io/matter-js/matterjs-server:1.3.0" "ghcr.io/matter-js/matterjs-server:1.3.0")"
[ "$line" = "ghcr.io/matter-js/matterjs-server:1.3.0 [current] [template default]" ] ||
  fail "current/template markers must render, got: $line"
line="$(lisa_image_menu_line matter "ghcr.io/matter-js/matterjs-server:1.3.1" "" "")"
[ "$line" = "ghcr.io/matter-js/matterjs-server:1.3.1 [known-issue]" ] ||
  fail "advisory marker must render, got: $line"
line="$(lisa_image_menu_line otbr "openthread/border-router:latest" \
  "openthread/border-router:latest" "")"
[ "$line" = "openthread/border-router:latest [current] [floating]" ] ||
  fail "floating marker must render, got: $line"
line="$(lisa_image_menu_line otbr "openthread/border-router:v2026.05.0" "" "")"
[ "$line" = "openthread/border-router:v2026.05.0 [blocked]" ] ||
  fail "blocked marker must render, got: $line"

# --- interactive selection: discovery mocked ---------------------------------
lisa_image_query_release_tags() {
  printf '1.3.1\n1.3.0\n1.2.0\n'
}

# The menu always renders (tagged current value included) with markers and
# the advisory note, and Enter keeps the clean current value as the default.
MATTER_SERVER_IMAGE="ghcr.io/matter-js/matterjs-server:1.3.0"
menu_output="$(lisa_configure_service_image matter <<< "" 2>&1)" ||
  fail "image selection with a tagged current value failed"
grep -q 'Matter Server container image' <<<"$menu_output" ||
  fail "the image menu section header must render"
grep -qE '[0-9]+\) ghcr.io/matter-js/matterjs-server:1.3.1 \[known-issue\]' <<<"$menu_output" ||
  fail "the known-issue candidate must be listed and annotated"
grep -q 'BLE regression' <<<"$menu_output" ||
  fail "the advisory note must be printed under the annotated candidate"
grep -qE '[0-9]+\) ghcr.io/matter-js/matterjs-server:1.3.0 \[current\] \[template default\]' <<<"$menu_output" ||
  fail "the current value must be listed with its markers"
grep -q 'c) Enter a custom image reference' <<<"$menu_output" ||
  fail "the custom option must be offered"

MATTER_SERVER_IMAGE="ghcr.io/matter-js/matterjs-server:1.3.0"
lisa_configure_service_image matter <<< "" >/dev/null 2>&1
[ "$MATTER_SERVER_IMAGE" = "ghcr.io/matter-js/matterjs-server:1.3.0" ] ||
  fail "Enter must keep the clean current value, got: $MATTER_SERVER_IMAGE"

# A numbered selection replaces the inherited default.
MATTER_SERVER_IMAGE="ghcr.io/matter-js/matterjs-server:1.3.0"
lisa_configure_service_image matter <<< "3" >/dev/null 2>&1
[ "$MATTER_SERVER_IMAGE" = "ghcr.io/matter-js/matterjs-server:1.2.0" ] ||
  fail "a numbered selection must be honored, got: $MATTER_SERVER_IMAGE"

# known-issue: selecting it repeats the warning and requires confirmation.
MATTER_SERVER_IMAGE="ghcr.io/matter-js/matterjs-server:1.3.0"
output="$(lisa_configure_service_image matter <<< $'1\ny\n' 2>&1)" ||
  fail "confirmed known-issue selection failed"
grep -q 'KNOWN ISSUE' <<<"$output" ||
  fail "selecting a known-issue image must repeat the warning"
lisa_configure_service_image matter <<< $'1\ny\n' >/dev/null 2>&1
[ "$MATTER_SERVER_IMAGE" = "ghcr.io/matter-js/matterjs-server:1.3.1" ] ||
  fail "a confirmed known-issue image must be accepted, got: $MATTER_SERVER_IMAGE"

# known-issue: declining the confirmation re-prompts for another image.
MATTER_SERVER_IMAGE="ghcr.io/matter-js/matterjs-server:1.3.0"
lisa_configure_service_image matter <<< $'1\nn\n2\n' >/dev/null 2>&1
[ "$MATTER_SERVER_IMAGE" = "ghcr.io/matter-js/matterjs-server:1.3.0" ] ||
  fail "declining the known-issue confirmation must allow another choice, got: $MATTER_SERVER_IMAGE"

# known-issue images are never the automatic default even when current.
MATTER_SERVER_IMAGE="ghcr.io/matter-js/matterjs-server:1.3.1"
lisa_configure_service_image matter <<< "" >/dev/null 2>&1
[ "$MATTER_SERVER_IMAGE" != "ghcr.io/matter-js/matterjs-server:1.3.1" ] ||
  fail "a known-issue current value must not be accepted silently as default"

# blocked: the selection is refused (menu number and custom input alike).
lisa_image_query_release_tags() {
  printf 'v2026.07.1\nv2026.06.0\nv2026.05.2\n'
}
OTBR_IMAGE="openthread/border-router:v2026.06.0"
output="$(lisa_configure_service_image otbr <<< $'openthread/border-router:v2026.05.0\n2\n' 2>&1)" ||
  fail "selection after a blocked refusal failed"
grep -q 'BLOCKED image' <<<"$output" ||
  fail "a blocked image must be refused with its note"
lisa_configure_service_image otbr <<< $'openthread/border-router:v2026.05.0\n2\n' >/dev/null 2>&1
[ "$OTBR_IMAGE" = "openthread/border-router:v2026.06.0" ] ||
  fail "after a blocked refusal the next choice must win, got: $OTBR_IMAGE"

# blocked as the only input: the selection fails instead of hanging.
OTBR_IMAGE="openthread/border-router:v2026.06.0"
if (lisa_configure_service_image otbr <<< 'openthread/border-router:v2026.05.0') >/dev/null 2>&1; then
  fail "end-of-input after a blocked refusal must fail, not silently accept"
fi

# custom input: the c option prompts for a full reference.
OTBR_IMAGE="openthread/border-router:v2026.06.0"
lisa_configure_service_image otbr <<< $'c\nregistry.local/custom/otbr:v9.9.9\n' >/dev/null 2>&1
[ "$OTBR_IMAGE" = "registry.local/custom/otbr:v9.9.9" ] ||
  fail "the custom option must accept a full reference, got: $OTBR_IMAGE"

# custom input: a full reference typed directly is accepted too.
OTBR_IMAGE="openthread/border-router:v2026.06.0"
lisa_configure_service_image otbr <<< $'openthread/border-router@sha256:'"$(printf 'a%.0s' $(seq 1 64))"$'\n' >/dev/null 2>&1
case "$OTBR_IMAGE" in
  openthread/border-router@sha256:*) ;;
  *) fail "a digest reference typed directly must be accepted, got: $OTBR_IMAGE" ;;
esac

# --- offline fallback: the menu still renders local choices ------------------
lisa_image_query_release_tags() { return 1; }
OTBR_IMAGE="openthread/border-router:v2026.04.0"
menu_output="$(lisa_configure_service_image otbr <<< "" 2>&1)" ||
  fail "offline image selection failed"
grep -q 'Could not resolve release tags' <<<"$menu_output" ||
  fail "offline discovery must warn, not fail the wizard"
grep -qE '[0-9]+\) openthread/border-router:v2026.04.0 \[current\]' <<<"$menu_output" ||
  fail "offline the current value must still be offered"
grep -qE '[0-9]+\) openthread/border-router:latest \[template default\] \[floating\]' <<<"$menu_output" ||
  fail "offline the template default must still be offered"
lisa_configure_service_image otbr <<< "" >/dev/null 2>&1
[ "$OTBR_IMAGE" = "openthread/border-router:v2026.04.0" ] ||
  fail "offline Enter must keep the pinned current value, got: $OTBR_IMAGE"

# blocked selected images are rejected at review time.
LISA_COMPOSE_SERVICES="otbr"
OTBR_IMAGE="openthread/border-router:v2026.05.0"
# shellcheck disable=SC1091
. "$REPO_ROOT/lib/compose.sh"
if lisa_reject_blocked_selected_images >/dev/null 2>&1; then
  fail "a blocked selected image must fail the review-time check"
fi
OTBR_IMAGE="openthread/border-router:v2026.06.0"
lisa_reject_blocked_selected_images ||
  fail "a non-blocked selected image must pass the review-time check"

echo "Image advisory tests passed."
