#!/usr/bin/env bash
# Runs every tests/unit/test_*.sh in its own subshell and reports a summary.
set -Eeuo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

total_pass=0
total_fail=0
failed_files=()

for test_file in "$TEST_DIR"/test_*.sh; do
    printf '== %s ==\n' "$(basename "$test_file")"
    if bash "$test_file"; then
        total_pass=$((total_pass + 1))
    else
        total_fail=$((total_fail + 1))
        failed_files+=("$(basename "$test_file")")
    fi
    printf '\n'
done

printf '%d test files passed, %d failed\n' "$total_pass" "$total_fail"
if [[ "$total_fail" -gt 0 ]]; then
    printf 'Failed: %s\n' "${failed_files[*]}"
    exit 1
fi
exit 0
