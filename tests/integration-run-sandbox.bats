#!/usr/bin/env bats
load helpers/setup

setup() { cdc_setup; }
teardown() { cdc_teardown; }

@test "bin/cdc contains no security find-generic-password calls" {
	local repo_root
	repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	! grep -n 'security find-generic-password' "$repo_root/bin/cdc"
}

@test "bin/cdc contains no inject_credentials calls" {
	local repo_root
	repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	! grep -n 'inject_credentials' "$repo_root/bin/cdc"
}
