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

@test "mock sbx accepts 'ports --publish' and logs argv" {
	run sbx ports my-sandbox --publish 3000
	[ "$status" -eq 0 ]
	run cdc_log_line 1
	[[ "$output" == "sbx ports my-sandbox --publish 3000" ]]
}

@test "mock sbx accepts 'ports --unpublish' and logs argv" {
	run sbx ports my-sandbox --unpublish 3000
	[ "$status" -eq 0 ]
	run cdc_log_line 1
	[[ "$output" == "sbx ports my-sandbox --unpublish 3000" ]]
}

@test "mock sbx 'ports --json' emits canned JSON on stdout" {
	export CDC_MOCK_PORTS_JSON='[{"sandbox_port":3000,"host_ip":"127.0.0.1","host_port":54321,"protocol":"tcp"}]'
	run sbx ports my-sandbox --json
	[ "$status" -eq 0 ]
	[[ "$output" == *'"sandbox_port":3000'* ]]
}

@test "publish_ports runs sbx ports --publish for each spec in order" {
	CDC_PUBLISH_SPECS=(3000 8080:80)
	export CDC_MOCK_PORTS_JSON='[]'
	run publish_ports test-sandbox
	[ "$status" -eq 0 ]
	local line1 line2
	line1="$(cdc_log_line 1)"
	line2="$(cdc_log_line 2)"
	[[ "$line1" == "sbx ports test-sandbox --publish 3000" ]]
	[[ "$line2" == "sbx ports test-sandbox --publish 8080:80" ]]
}

@test "publish_ports returns nonzero if sbx publish fails" {
	CDC_PUBLISH_SPECS=(3000)
	export CDC_MOCK_PUBLISH_EXIT=2
	export CDC_MOCK_PORTS_JSON='[]'
	run publish_ports test-sandbox
	[ "$status" -eq 2 ]
}

@test "print_resolved_bindings prints 'cdc: published' line to stderr" {
	CDC_PUBLISH_SPECS=(3000)
	export CDC_MOCK_PORTS_JSON='[{"sandbox_port":3000,"host_ip":"127.0.0.1","host_port":54321,"protocol":"tcp"}]'
	run bash -c "
		set -euo pipefail
		export PATH='$PATH'
		export CDC_MOCK_PORTS_JSON='$CDC_MOCK_PORTS_JSON'
		export CDC_TEST_LOG='$CDC_TEST_LOG'
		export HOME='$HOME'
		source '$(cd "${BATS_TEST_DIRNAME}/.." && pwd)/bin/cdc'
		CDC_PUBLISH_SPECS=(3000)
		print_resolved_bindings test-sandbox 2>&1
	"
	[ "$status" -eq 0 ]
	[[ "$output" == *"cdc: published http://127.0.0.1:54321 -> sandbox:3000 (tcp)"* ]]
}

@test "unpublish_ports runs sbx ports --unpublish for each spec" {
	CDC_PUBLISH_SPECS=(3000 8080:80)
	run unpublish_ports test-sandbox
	[ "$status" -eq 0 ]
	[[ "$(cdc_log_line 1)" == "sbx ports test-sandbox --unpublish 3000" ]]
	[[ "$(cdc_log_line 2)" == "sbx ports test-sandbox --unpublish 8080:80" ]]
}

@test "unpublish_ports swallows errors and continues" {
	CDC_PUBLISH_SPECS=(3000 8080:80)
	export CDC_MOCK_UNPUBLISH_EXIT=1
	run unpublish_ports test-sandbox
	[ "$status" -eq 0 ]
	[[ "$(cdc_log_line 1)" == *"--unpublish 3000"* ]]
	[[ "$(cdc_log_line 2)" == *"--unpublish 8080:80"* ]]
	[[ "$output" == *"cdc: warn: could not unpublish 3000"* ]]
	[[ "$output" == *"cdc: warn: could not unpublish 8080:80"* ]]
}

@test "unpublish_ports is a no-op when CDC_PUBLISH_SPECS is empty" {
	CDC_PUBLISH_SPECS=()
	run unpublish_ports test-sandbox
	[ "$status" -eq 0 ]
	run wc -l <"$CDC_TEST_LOG"
	[ "$output" -eq 0 ]
}

@test "--cdc-help lists --cdc-publish" {
	local repo_root
	repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	run "$repo_root/bin/cdc" --cdc-help
	[ "$status" -eq 0 ]
	[[ "$output" == *"--cdc-publish"* ]]
}
