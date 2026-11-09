#!/usr/bin/env bash
# Same-volume app replacement transaction. Sourced by install.sh and its tests.
# Only a verified, committed install may discard the previous app.

begin_install_transaction() {
  INSTALL_TRANSACTION_DIR="$(mktemp -d "$COTYPE_INSTALL_DIR/.Cotype.install.XXXXXX")"
  STAGED_APP="$INSTALL_TRANSACTION_DIR/staged.app"
  BACKUP_APP="$INSTALL_TRANSACTION_DIR/previous.app"
  FAILED_APP="$INSTALL_TRANSACTION_DIR/rejected.app"
  INSTALL_COMMITTED=0
  INSTALL_SWAP_STARTED=0
  trap cleanup_install_transaction EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

cleanup_install_transaction() {
  local outcome=$?
  trap - EXIT HUP INT TERM
  if [[ "$INSTALL_COMMITTED" == "1" ]]; then
    rm -rf "$INSTALL_TRANSACTION_DIR"
    return "$outcome"
  fi

  if [[ "$outcome" == "0" ]]; then outcome=1; fi

  # A signal can arrive after either rename and before its caller resumes.
  # Inspect the actual backup, rather than a flag set after moving it.
  if [[ -d "$BACKUP_APP" ]]; then
    if [[ -e "$COTYPE_APP" ]]; then
      if ! mv "$COTYPE_APP" "$FAILED_APP"; then
        warn "Rollback could not move the replacement. Previous app preserved at $BACKUP_APP"
        exit 1
      fi
    fi
    if ! mv "$BACKUP_APP" "$COTYPE_APP"; then
      warn "Rollback could not restore the previous app. Preserved at $BACKUP_APP"
      exit 1
    fi
    warn "Previous app restored at $COTYPE_APP"
  elif [[ "$INSTALL_SWAP_STARTED" == "1" && -e "$COTYPE_APP" ]]; then
    # First install has no previous bundle. Quarantine an unverified replacement.
    if ! mv "$COTYPE_APP" "$FAILED_APP"; then
      warn "Unverified replacement remains at $COTYPE_APP"
      exit 1
    fi
  fi

  # Retain a rejected replacement for diagnosis; never delete a rollback copy.
  if [[ -e "$FAILED_APP" ]]; then
    warn "Rejected replacement preserved at $FAILED_APP"
  else
    rm -rf "$INSTALL_TRANSACTION_DIR"
  fi
  exit "$outcome"
}

commit_install_transaction() {
  INSTALL_COMMITTED=1
  rm -rf "$INSTALL_TRANSACTION_DIR"
  trap - EXIT HUP INT TERM
}
