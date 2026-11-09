#!/usr/bin/env python3
"""Exercise real rollback functions in isolated, same-volume temp directories.

Silent on pass; no app is stopped, installed or opened by these tests.
"""
import os
from pathlib import Path
import subprocess
import tempfile

HELPER = Path(__file__).with_name("install-transaction.sh").resolve()
PRELUDE = r'''
set -euo pipefail
warn() { :; }
source "$TRANSACTION_HELPER"
begin_install_transaction
mkdir "$STAGED_APP"
printf new > "$STAGED_APP/marker"
'''


def run_case(name, commands, *, existing=True, expected=17, restored=True, rejected=False):
    with tempfile.TemporaryDirectory(prefix="cotype-install-test-") as directory:
        root = Path(directory)
        app = root / "Cotype.app"
        if existing:
            app.mkdir()
            (app / "marker").write_text("old")
        result = subprocess.run(
            ["bash", "-c", PRELUDE + commands],
            env={**os.environ, "TRANSACTION_HELPER": str(HELPER),
                 "COTYPE_INSTALL_DIR": str(root), "COTYPE_APP": str(app)},
            capture_output=True, text=True, timeout=10,
        )
        assert result.returncode == expected, f"{name}: exit {result.returncode}, expected {expected}"
        if restored:
            assert (app / "marker").read_text() == "old", f"{name}: old app was not restored"
        elif expected == 0:
            assert (app / "marker").read_text() == "new", f"{name}: new app missing"
        else:
            assert not app.exists(), f"{name}: unverified first install remains active"
        leftovers = list(root.glob(".Cotype.install.*"))
        if rejected:
            assert len(leftovers) == 1, f"{name}: rejected app was not preserved"
            assert (leftovers[0] / "rejected.app" / "marker").read_text() == "new"
            assert not (leftovers[0] / "previous.app").exists(), f"{name}: old app not restored"
        else:
            assert not leftovers, f"{name}: transaction was not cleaned up"


def check_failed_rollback_preserves_backup():
    for failure in ("restore", "quarantine"):
        with tempfile.TemporaryDirectory(prefix="cotype-rollback-test-") as directory:
            root = Path(directory)
            app = root / "Cotype.app"
            app.mkdir()
            (app / "marker").write_text("old")
            commands = r''' 
mv "$COTYPE_APP" "$BACKUP_APP"
INSTALL_SWAP_STARTED=1
mv "$STAGED_APP" "$COTYPE_APP"
mv() {
  if [[ "$FAIL_MOVE" == "restore" && "$1" == "$BACKUP_APP" ]]; then return 1; fi
  if [[ "$FAIL_MOVE" == "quarantine" && "$1" == "$COTYPE_APP" ]]; then return 1; fi
  command mv "$@"
}
exit 17
'''
            result = subprocess.run(
                ["bash", "-c", PRELUDE + commands],
                env={**os.environ, "TRANSACTION_HELPER": str(HELPER),
                     "COTYPE_INSTALL_DIR": str(root), "COTYPE_APP": str(app), "FAIL_MOVE": failure},
                capture_output=True, text=True, timeout=10,
            )
            assert result.returncode != 0, "failed rollback must not report success"
            transactions = list(root.glob(".Cotype.install.*"))
            assert len(transactions) == 1, "failed rollback must preserve transaction"
            assert (transactions[0] / "previous.app" / "marker").read_text() == "old", "failed rollback lost the old app"


def main():
    backup = 'mv "$COTYPE_APP" "$BACKUP_APP"\n'
    swap = 'INSTALL_SWAP_STARTED=1\nmv "$STAGED_APP" "$COTYPE_APP"\n'
    cases = [
        ("failure-before-backup", 'exit 17', {}),
        ("failure-after-backup", backup + 'exit 17', {}),
        ("failed-replacement-rename", backup + 'mv() { if [[ "$1" == "$STAGED_APP" ]]; then return 1; fi; command mv "$@"; }\nINSTALL_SWAP_STARTED=1\nif ! mv "$STAGED_APP" "$COTYPE_APP"; then exit 17; fi', {}),
        ("signal-after-backup", backup + 'kill -TERM $$', {"expected": 143}),
        ("failure-after-swap", backup + swap + 'exit 17', {"rejected": True}),
        ("signal-after-swap", backup + swap + 'kill -HUP $$', {"expected": 129, "rejected": True}),
        ("uncommitted-normal-exit", backup + swap, {"expected": 1, "rejected": True}),
        ("first-install-failure", swap + 'exit 17', {"existing": False, "restored": False, "rejected": True}),
        ("successful-update", backup + swap + 'commit_install_transaction', {"expected": 0, "restored": False}),
        ("successful-first-install", swap + 'commit_install_transaction', {"existing": False, "expected": 0, "restored": False}),
    ]
    failures = []
    for name, commands, options in cases:
        try:
            run_case(name, commands, **options)
        except Exception as error:
            failures.append(f"scripts/install-transaction.sh:1: {error} -> fix rollback transaction")
    try:
        check_failed_rollback_preserves_backup()
    except Exception as error:
        failures.append(f"scripts/install-transaction.sh:1: {error} -> preserve backup after failed rollback")
    for failure in failures:
        print(failure)
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
