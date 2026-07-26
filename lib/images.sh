#!/usr/bin/env bash

lisa_image_ref_for_service() {
  local variable
  # Used via bash indirection "${!variable}" below - not dead, despite IDE hints.
  variable="$(lisa_service_image_variable "$1")" || return 1
  printf '%s\n' "${!variable:-}"
}

lisa_is_pinned_image() {
  [[ "$1" =~ @sha256:[0-9a-fA-F]{64}$ ]]
}

lisa_print_selected_images() {
  local service image pin_status
  if [ -z "$(lisa_selected_services)" ]; then
    printf '  %s\n' '(none - no services selected)'
    return 0
  fi
  for service in $(lisa_selected_services); do
    image="$(lisa_image_ref_for_service "$service")"
    pin_status=floating
    lisa_is_pinned_image "$image" && pin_status=pinned
    printf '  %-15s %s [%s]\n' "$service" "$image" "$pin_status"
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
