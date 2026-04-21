#!/usr/bin/env bats
load helpers/setup

setup() {
	cdc_setup
	cdc_source
}
teardown() { cdc_teardown; }

@test "--cdc-publish populates CDC_PUBLISH_SPECS" {
	CDC_PUBLISH_SPECS=()
	CLAUDE_ARGS=()
	parse_args --cdc-publish 3000
	[ "${#CDC_PUBLISH_SPECS[@]}" -eq 1 ]
	[ "${CDC_PUBLISH_SPECS[0]}" = "3000" ]
}

@test "repeated --cdc-publish accumulates in order" {
	CDC_PUBLISH_SPECS=()
	CLAUDE_ARGS=()
	parse_args --cdc-publish 3000 --cdc-publish 8080:80
	[ "${#CDC_PUBLISH_SPECS[@]}" -eq 2 ]
	[ "${CDC_PUBLISH_SPECS[0]}" = "3000" ]
	[ "${CDC_PUBLISH_SPECS[1]}" = "8080:80" ]
}

@test "--cdc-publish without a value exits nonzero with a clear message" {
	run bash -c "source '$(cd "${BATS_TEST_DIRNAME}/.." && pwd)/bin/cdc'; parse_args --cdc-publish"
	[ "$status" -ne 0 ]
	[[ "$output" == *"--cdc-publish requires a <spec> value"* ]]
}

@test "--cdc-publish value is not forwarded to CLAUDE_ARGS" {
	CDC_PUBLISH_SPECS=()
	CLAUDE_ARGS=()
	parse_args --cdc-publish 3000 -c
	[ "${#CLAUDE_ARGS[@]}" -eq 1 ]
	[ "${CLAUDE_ARGS[0]}" = "-c" ]
}

@test "--cdc-no-sandbox with --cdc-publish exits with a clear conflict message" {
	local repo_root
	repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	run bash -c "'$repo_root/bin/cdc' --cdc-no-sandbox --cdc-publish 3000 --cdc-dry-run"
	[ "$status" -ne 0 ]
	[[ "$output" == *"--cdc-publish cannot be combined with --cdc-no-sandbox"* ]]
}
