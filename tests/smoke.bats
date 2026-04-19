#!/usr/bin/env bats
load helpers/setup

setup() { cdc_setup; }
teardown() { cdc_teardown; }

@test "mock sbx is on PATH" {
	run which sbx
	[ "$status" -eq 0 ]
	[[ "$output" == *"$CDC_TEST_DIR"* ]]
}

@test "sourcing bin/cdc does not invoke CLI" {
	local repo_root
	repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	run bash -c "source $repo_root/bin/cdc; echo sourced-ok"
	[ "$status" -eq 0 ]
	[ "$output" = "sourced-ok" ]
}

@test "mock sbx records invocations" {
	sbx create claude /tmp
	run cdc_log_line 1
	[[ "$output" == "sbx create claude /tmp" ]]
}
