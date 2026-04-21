#!/usr/bin/env bats
load helpers/setup

setup() {
	cdc_setup
}
teardown() { cdc_teardown; }

@test "dry-run with --cdc-publish shows PUBLISH block" {
	local repo_root
	repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	cd "$CDC_TEST_DIR"
	run bash -c "'$repo_root/bin/cdc' --cdc-publish 3000 --cdc-publish 8080:80 --cdc-dry-run"
	[ "$status" -eq 0 ]
	[[ "$output" == *"PUBLISH (would run after create):"* ]]
	[[ "$output" == *"--publish 3000"* ]]
	[[ "$output" == *"--publish 8080:80"* ]]
}

@test "dry-run without --cdc-publish omits PUBLISH block" {
	local repo_root
	repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	cd "$CDC_TEST_DIR"
	run bash -c "'$repo_root/bin/cdc' --cdc-dry-run"
	[ "$status" -eq 0 ]
	[[ "$output" != *"PUBLISH"* ]]
}

@test "dry-run with --cdc-publish does NOT invoke sbx ports" {
	local repo_root
	repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	cd "$CDC_TEST_DIR"
	run bash -c "'$repo_root/bin/cdc' --cdc-publish 3000 --cdc-dry-run"
	[ "$status" -eq 0 ]
	! grep -q 'sbx ports' "$CDC_TEST_LOG"
}
