#!/usr/bin/env bash

# Shared container-image helpers: image policy validation, the Git-managed
# image advisory catalog, remote release-tag discovery (Docker Hub and
# GHCR), and the generic interactive image-selection menu used by the setup
# wizard and 'lisa-edge service add'. Service identity (image variable,
# default repository, release-tag filter) comes from services/registry.sh.
#
# Network use is bounded (LISA_IMAGE_QUERY_TIMEOUT per request,
# LISA_IMAGE_QUERY_MAX_PAGES pages) and always optional: when discovery
# fails or is disabled (LISA_IMAGE_QUERY_DISABLE=1), the menu still offers
# the current, template, and cataloged choices.

LISA_IMAGES_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

lisa_image_ref_for_service() {
  local variable
  # Used via bash indirection "${!variable}" below - not dead, despite IDE hints.
  variable="$(lisa_service_image_variable "$1")" || return 1
  printf '%s\n' "${!variable:-}"
}

lisa_is_pinned_image() {
  [[ "$1" =~ @sha256:[0-9a-fA-F]{64}$ ]]
}

# True when the reference uses a floating (mutable, non-release) tag: no tag
# at all, or one of the well-known moving tags. Digest-pinned references and
# release tags are not floating.
lisa_image_ref_is_floating() {
  local image="$1" last tag
  lisa_is_pinned_image "$image" && return 1
  last="${image##*/}"
  case "$last" in
    *:*) tag="${last##*:}" ;;
    *) return 0 ;;
  esac
  case "$tag" in
    latest|main|master|stable|nightly|dev|edge) return 0 ;;
    *) return 1 ;;
  esac
}

# Print the .env.template default value for an environment variable, with
# surrounding quotes stripped. Prints nothing when the template has none.
lisa_image_template_default() {
  local variable="$1"
  local file="${LISA_ENV_TEMPLATE_FILE:-$LISA_IMAGES_REPO_ROOT/.env.template}"
  local value
  [ -f "$file" ] || return 0
  value="$(grep -E "^${variable}=" "$file" || true)"
  [ -n "$value" ] || return 0
  value="${value##*$'\n'}"
  value="${value#*=}"
  value="${value%\"}"; value="${value#\"}"
  value="${value%\'}"; value="${value#\'}"
  printf '%s\n' "$value"
}

# ---------------------------------------------------------------------------
# Git-managed image advisory catalog (services/image-advisories.tsv)
#
# Constrained TSV, one advisory per line:
#   service-key<TAB>full-image-reference<TAB>status<TAB>note
# Blank lines and '#' comments are allowed. Supported statuses:
#   known-issue  shown with the note; never the automatic default; selecting
#                it repeats the warning and requires explicit confirmation
#   blocked      shown as blocked; the selection is refused
# The catalog is static and reviewed through Git: there is no runtime CRUD.
# Absence from the catalog means only that LISA Edge has no recorded issue
# for that exact image reference (it does not mean "tested").
# ---------------------------------------------------------------------------

lisa_image_advisory_file() {
  printf '%s\n' "${LISA_IMAGE_ADVISORY_FILE:-$LISA_IMAGES_REPO_ROOT/services/image-advisories.tsv}"
}

# Look up the advisory for one exact (service, image) pair.
# Prints "status<TAB>note" and returns 0 when found; returns 1 otherwise.
lisa_image_advisory_lookup() {
  local service="$1" image="$2"
  local file line svc img status note
  file="$(lisa_image_advisory_file)"
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    IFS=$'\t' read -r svc img status note <<<"$line"
    if [ "$svc" = "$service" ] && [ "$img" = "$image" ]; then
      printf '%s\t%s\n' "$status" "$note"
      return 0
    fi
  done < "$file"
  return 1
}

# Print every cataloged image reference for one service, one per line.
lisa_image_advisory_images_for_service() {
  local service="$1"
  local file line svc img status note
  file="$(lisa_image_advisory_file)"
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    IFS=$'\t' read -r svc img status note <<<"$line"
    [ "$svc" = "$service" ] && printf '%s\n' "$img"
  done < "$file"
  return 0
}

# Validate the complete advisory catalog. Malformed records are rejected:
# wrong field count (embedded tabs), empty fields, unknown service keys,
# unsupported statuses, carriage returns, unsafe image references. Prints
# every problem to stderr; returns 1 when any record is invalid.
lisa_image_advisories_validate() {
  local file="${1:-$(lisa_image_advisory_file)}"
  local line line_no=0 rc=0 field_count svc img status note
  if [ ! -f "$file" ]; then
    echo "Image advisory catalog not found: $file" >&2
    return 1
  fi
  if ! declare -F lisa_service_image_variable >/dev/null; then
    # shellcheck disable=SC1091
    . "$LISA_IMAGES_REPO_ROOT/services/registry.sh"
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in
      *$'\r'*)
        echo "advisory line $line_no: carriage return is not allowed (use plain LF)." >&2
        rc=1
        continue
        ;;
    esac
    field_count="$(awk -F'\t' '{print NF; exit}' <<<"$line")"
    if [ "$field_count" -ne 4 ]; then
      echo "advisory line $line_no: expected exactly 4 tab-separated fields, found $field_count." >&2
      rc=1
      continue
    fi
    IFS=$'\t' read -r svc img status note <<<"$line"
    if [ -z "$svc" ] || [ -z "$img" ] || [ -z "$status" ] || [ -z "$note" ]; then
      echo "advisory line $line_no: empty fields are not allowed." >&2
      rc=1
      continue
    fi
    if ! lisa_service_image_variable "$svc" >/dev/null 2>&1; then
      echo "advisory line $line_no: unknown service key: $svc" >&2
      rc=1
    fi
    if ! [[ "$img" =~ ^[A-Za-z0-9._/:@-]+$ ]]; then
      echo "advisory line $line_no: unsafe image reference: $img" >&2
      rc=1
    fi
    case "$status" in
      known-issue|blocked) ;;
      *)
        echo "advisory line $line_no: unsupported status: $status (known-issue or blocked)." >&2
        rc=1
        ;;
    esac
    case "$note" in
      *"'"*)
        echo "advisory line $line_no: single quotes are not allowed in the note." >&2
        rc=1
        ;;
    esac
  done < "$file"
  return "$rc"
}

# ---------------------------------------------------------------------------
# Remote release-tag discovery (provider adapters)
#
# lisa_image_query_release_tags <repository> <tag-filter-ere> prints matching
# release tags newest-first (version sort, unique) or fails when the
# registry is unsupported, unreachable, disabled, or has no matching tag.
# Callers must treat failure as "discovery unavailable", never as a wizard
# error. All fetches go through lisa_image_fetch_url* (overridable in tests)
# with a bounded timeout and bounded pagination.
# ---------------------------------------------------------------------------

# Fetch one URL with a bounded timeout. Overridable in tests.
lisa_image_fetch_url() {
  command -v curl >/dev/null 2>&1 || return 1
  curl -fsS --max-time "${LISA_IMAGE_QUERY_TIMEOUT:-8}" "$1" 2>/dev/null
}

# Fetch one URL with a bearer token (GHCR). Overridable in tests.
lisa_image_fetch_url_auth() {
  command -v curl >/dev/null 2>&1 || return 1
  curl -fsS --max-time "${LISA_IMAGE_QUERY_TIMEOUT:-8}" \
    -H "Authorization: Bearer $2" "$1" 2>/dev/null
}

# Print every tag name found in Docker Hub tag-list JSON on stdin.
lisa_image_tags_from_dockerhub_page() {
  grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+"' |
    sed -E 's/.*"name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true
}

# Print the "next" page URL from Docker Hub tag-list JSON on stdin, or
# nothing at the last page. Only hub.docker.com URLs are followed, so a
# hostile response cannot redirect the query elsewhere.
lisa_image_dockerhub_next_url() {
  local url
  url="$(grep -oE '"next"[[:space:]]*:[[:space:]]*"[^"]+"' |
    sed -E 's/.*"next"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)"
  url="${url%%$'\n'*}"
  case "$url" in
    https://hub.docker.com/*) printf '%s\n' "$url" ;;
    *) : ;;
  esac
}

# Print every tag from Docker Hub for a repository, following pagination
# with a bounded page count. Fails when offline or nothing was fetched.
lisa_image_dockerhub_query_tags() {
  local repository="$1" path url max_pages pages=0 response all_tags=""
  case "$repository" in
    */*) path="$repository" ;;
    *) path="library/$repository" ;;
  esac
  url="https://hub.docker.com/v2/repositories/$path/tags?page_size=100"
  max_pages="${LISA_IMAGE_QUERY_MAX_PAGES:-5}"
  while [ -n "$url" ] && [ "$pages" -lt "$max_pages" ]; do
    response="$(lisa_image_fetch_url "$url")" || return 1
    all_tags+="$(printf '%s' "$response" | lisa_image_tags_from_dockerhub_page)"$'\n'
    url="$(printf '%s' "$response" | lisa_image_dockerhub_next_url)"
    pages=$((pages + 1))
  done
  [ -n "${all_tags//[$'\n ']/}" ] || return 1
  printf '%s' "$all_tags"
}

# Print the tag names from a GHCR tags/list JSON document on stdin.
lisa_image_tags_from_ghcr_page() {
  grep -oE '"tags"[[:space:]]*:[[:space:]]*\[[^]]*\]' |
    grep -oE '"[^"]*"' | tr -d '"' | grep -v '^tags$' || true
}

# Print every tag from GHCR for a repository (ghcr.io/owner/name) using the
# anonymous pull token flow. One bounded request per step; no pagination
# beyond the first page (a known limitation - recent releases are expected
# on it; a custom reference stays available regardless).
lisa_image_ghcr_query_tags() {
  local repository="$1" path token response
  path="${repository#ghcr.io/}"
  response="$(lisa_image_fetch_url \
    "https://ghcr.io/token?service=ghcr.io&scope=repository:$path:pull")" || return 1
  token="$(printf '%s' "$response" |
    grep -oE '"token"[[:space:]]*:[[:space:]]*"[^"]+"' |
    sed -E 's/.*"token"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)"
  token="${token%%$'\n'*}"
  [ -n "$token" ] || return 1
  response="$(lisa_image_fetch_url_auth \
    "https://ghcr.io/v2/$path/tags/list?n=${LISA_IMAGE_QUERY_PAGE_SIZE:-200}" \
    "$token")" || return 1
  printf '%s' "$response" | lisa_image_tags_from_ghcr_page
}

# Print the release tags for a repository that match the filter, newest
# first and unique. Fails (non-zero) when discovery is disabled, the
# registry is unsupported, the fetch fails, or no tag matches.
lisa_image_query_release_tags() {
  local repository="$1" tag_filter="$2" names="" tags
  [ "${LISA_IMAGE_QUERY_DISABLE:-0}" = "1" ] && return 1
  case "$repository" in
    ghcr.io/*)
      names="$(lisa_image_ghcr_query_tags "$repository")" || return 1
      ;;
    *.*/*|*:*/*)
      # Unsupported third-party registry host: no discovery.
      return 1
      ;;
    *)
      names="$(lisa_image_dockerhub_query_tags "$repository")" || return 1
      ;;
  esac
  tags="$(printf '%s\n' "$names" | grep -E "$tag_filter" | sort -urV || true)"
  [ -n "$tags" ] || return 1
  printf '%s\n' "$tags"
}

# ---------------------------------------------------------------------------
# Selected-image summary and policy validation
# ---------------------------------------------------------------------------

lisa_print_selected_images() {
  local service image pin_status entry status note
  if [ -z "$(lisa_selected_services)" ]; then
    printf '  %s\n' '(none - no services selected)'
    return 0
  fi
  for service in $(lisa_selected_services); do
    image="$(lisa_image_ref_for_service "$service")"
    pin_status=floating
    lisa_is_pinned_image "$image" && pin_status=pinned
    if entry="$(lisa_image_advisory_lookup "$service" "$image")"; then
      status="${entry%%$'\t'*}"
      note="${entry#*$'\t'}"
      printf '  %-15s %s [%s] [%s]\n' "$service" "$image" "$pin_status" "$status"
      printf '  %-15s   %s\n' '' "$note"
    else
      printf '  %-15s %s [%s]\n' "$service" "$image" "$pin_status"
    fi
  done
}

lisa_validate_selected_images() {
  local require_pinned="${LISA_REQUIRE_PINNED_IMAGES:-0}"
  local service image

  case "$require_pinned" in
    0|1) ;;
    *) echo "LISA_REQUIRE_PINNED_IMAGES must be 0 or 1." >&2; return 1 ;;
  esac

  for service in $(lisa_selected_services); do
    image="$(lisa_image_ref_for_service "$service")"
    [ -n "$image" ] || {
      echo "Container image reference is empty for selected service: $service" >&2
      return 1
    }
    if [ "$require_pinned" = "1" ] && ! lisa_is_pinned_image "$image"; then
      echo "Selected service $service must use an immutable @sha256 digest: $image" >&2
      return 1
    fi
  done
}

# Fail when any SELECTED image is blocked by the advisory catalog. Used at
# configuration review time (wizard/service add), not by the deploy engine:
# a catalog update must never brick an already-running host.
lisa_reject_blocked_selected_images() {
  local service image entry rc=0
  for service in $(lisa_selected_services); do
    image="$(lisa_image_ref_for_service "$service")"
    [ -n "$image" ] || continue
    if entry="$(lisa_image_advisory_lookup "$service" "$image")"; then
      if [ "${entry%%$'\t'*}" = "blocked" ]; then
        echo "Selected $service image is BLOCKED by the advisory catalog: $image" >&2
        echo "  ${entry#*$'\t'}" >&2
        rc=1
      fi
    fi
  done
  return "$rc"
}

# ---------------------------------------------------------------------------
# Generic interactive image selection
# ---------------------------------------------------------------------------

# One rendered menu line for an image candidate (pure; unit-tested):
#   <image> [current] [template default] [floating] [known-issue|blocked]
lisa_image_menu_line() {
  local service="$1" image="$2" current="$3" template="$4"
  local line="$image" entry
  [ -n "$current" ] && [ "$image" = "$current" ] && line+=" [current]"
  [ -n "$template" ] && [ "$image" = "$template" ] && line+=" [template default]"
  lisa_image_ref_is_floating "$image" && line+=" [floating]"
  if entry="$(lisa_image_advisory_lookup "$service" "$image")"; then
    line+=" [${entry%%$'\t'*}]"
  fi
  printf '%s\n' "$line"
}

# Append a unique, non-empty candidate to LISA_IMAGE_MENU_ITEMS.
lisa_image_menu_add() {
  local item="$1" existing
  [ -n "$item" ] || return 0
  for existing in "${LISA_IMAGE_MENU_ITEMS[@]}"; do
    [ "$existing" = "$item" ] && return 0
  done
  LISA_IMAGE_MENU_ITEMS+=("$item")
}

# True when the candidate may serve as the automatic default: it has no
# advisory record (known-issue images are never the automatic default) and
# does not use a floating tag.
lisa_image_candidate_is_clean() {
  local service="$1" image="$2"
  lisa_image_advisory_lookup "$service" "$image" >/dev/null && return 1
  lisa_image_ref_is_floating "$image" && return 1
  return 0
}

# Interactive image selection for one service. Requires the wizard UI
# helpers (install/provisioning/lib/ui.sh) and the service registry.
#
# The numbered menu is ALWAYS shown, whatever the current value looks like
# (floating, release tag, digest, or empty): existing values only prefill
# the default choice, they never suppress the step or the remote discovery.
# Menu sources: remotely discovered release tags (bounded, optional), the
# current configured value, the .env.template default, and every cataloged
# advisory image for the service. A custom full reference is always
# accepted. Blocked images are refused; known-issue images require explicit
# confirmation. Offline the menu still renders from the local sources.
lisa_configure_service_image() {
  local service="$1"
  local variable current template repository tag_filter display
  variable="$(lisa_service_image_variable "$service")" ||
    { echo "Unknown service key for image selection: $service" >&2; return 1; }
  current="${!variable:-}"
  template="$(lisa_image_template_default "$variable")"
  repository="$(lisa_service_image_repository "$service")"
  tag_filter="$(lisa_service_image_tag_filter "$service")"
  display="$(lisa_service_name "$service")"

  echo
  echo "--- $display container image ---"
  info "Resolving recent $repository release tags..."
  local discovered=""
  if ! discovered="$(lisa_image_query_release_tags "$repository" "$tag_filter")"; then
    discovered=""
    warn "Could not resolve release tags for $repository (offline, unsupported registry, or no release tags)."
    warn "Continuing with the current, template, and cataloged choices."
  fi

  LISA_IMAGE_MENU_ITEMS=()
  local tag count=0 cataloged
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    [ "$count" -lt "${LISA_IMAGE_CHOICE_COUNT:-5}" ] || break
    lisa_image_menu_add "$repository:$tag"
    count=$((count + 1))
  done <<<"$discovered"
  lisa_image_menu_add "$current"
  lisa_image_menu_add "$template"
  while IFS= read -r cataloged; do
    lisa_image_menu_add "$cataloged"
  done < <(lisa_image_advisory_images_for_service "$service")

  # Default preference: the clean current value, then the clean template
  # default, then the newest clean discovered release. A known-issue,
  # blocked, or floating value stays selectable but is never the automatic
  # default.
  local default_index="" candidate index=1
  local preferred=("$current" "$template" "${LISA_IMAGE_MENU_ITEMS[@]}")
  for candidate in "${preferred[@]}"; do
    [ -n "$candidate" ] || continue
    lisa_image_candidate_is_clean "$service" "$candidate" || continue
    for index in "${!LISA_IMAGE_MENU_ITEMS[@]}"; do
      if [ "${LISA_IMAGE_MENU_ITEMS[$index]}" = "$candidate" ]; then
        default_index=$((index + 1))
        break 2
      fi
    done
  done
  # Nothing clean: fall back to the current value (still confirmed below
  # when it carries a known-issue advisory; blocked never becomes default).
  if [ -z "$default_index" ] && [ -n "$current" ]; then
    local entry
    if ! entry="$(lisa_image_advisory_lookup "$service" "$current")" ||
      [ "${entry%%$'\t'*}" != "blocked" ]; then
      for index in "${!LISA_IMAGE_MENU_ITEMS[@]}"; do
        [ "${LISA_IMAGE_MENU_ITEMS[$index]}" = "$current" ] &&
          default_index=$((index + 1))
      done
    fi
  fi

  local item entry
  index=1
  for item in "${LISA_IMAGE_MENU_ITEMS[@]}"; do
    printf '  %d) %s\n' "$index" \
      "$(lisa_image_menu_line "$service" "$item" "$current" "$template")"
    if entry="$(lisa_image_advisory_lookup "$service" "$item")"; then
      printf '     %s\n' "${entry#*$'\t'}"
    fi
    index=$((index + 1))
  done
  echo "  c) Enter a custom image reference (repository[:tag] or repository@sha256:digest)"

  local prompt answer rc chosen status note confirmed iteration=0
  if [ -n "$default_index" ]; then
    prompt="Select an image for $service [$default_index]: "
  else
    prompt="Select an image for $service (number, c, or full reference): "
  fi
  while :; do
    rc=0
    read -r -p "$prompt" answer || rc=1
    # End-of-input may accept the (safe) default exactly once; after any
    # refused or invalid answer it fails instead of silently falling back.
    if [ "$rc" -eq 1 ] && [ "$iteration" -gt 0 ]; then
      die "Image selection for $service needs an interactive answer; the previous answer was refused."
    fi
    iteration=$((iteration + 1))
    answer="${answer:-$default_index}"
    if [ -z "$answer" ]; then
      [ "$rc" -eq 1 ] &&
        die "Image selection for $service needs an interactive answer (no acceptable default)."
      echo "Select a number, c, or type a full image reference." >&2
      continue
    fi
    if [[ "$answer" =~ ^[0-9]+$ ]] &&
      [ "$answer" -ge 1 ] && [ "$answer" -le "${#LISA_IMAGE_MENU_ITEMS[@]}" ]; then
      chosen="${LISA_IMAGE_MENU_ITEMS[$((answer - 1))]}"
    elif [ "$answer" = "c" ] || [ "$answer" = "C" ]; then
      ask_value chosen "Custom image reference" ""
    else
      chosen="$answer"
    fi
    if ! [[ "$chosen" =~ ^[A-Za-z0-9._/:@-]+$ ]]; then
      [ "$rc" -eq 1 ] && die "Invalid image reference for $service: $chosen"
      echo "Image references may only contain letters, digits, and . _ / : @ - characters." >&2
      continue
    fi
    if entry="$(lisa_image_advisory_lookup "$service" "$chosen")"; then
      status="${entry%%$'\t'*}"
      note="${entry#*$'\t'}"
      if [ "$status" = "blocked" ]; then
        warn "BLOCKED image for $service: $chosen"
        warn "  $note"
        [ "$rc" -eq 1 ] && die "The selected $service image is blocked; select another image."
        echo "This image is blocked; select another image." >&2
        continue
      fi
      warn "KNOWN ISSUE for $chosen:"
      warn "  $note"
      confirmed=no
      ask_yes_no confirmed "Use this image anyway" no
      if [ "$confirmed" != "yes" ]; then
        [ "$rc" -eq 1 ] && die "The known-issue $service image was not confirmed; select another image."
        continue
      fi
    fi
    printf -v "$variable" '%s' "$chosen"
    info "Selected $display image: $chosen"
    return 0
  done
}
