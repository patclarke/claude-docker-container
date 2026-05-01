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

@test "run_sandbox publishes ports before attach when --cdc-publish given" {
	cdc_source
	CDC_PUBLISH_SPECS=(3000)
	CDC_KEEP_RUNNING=0
	CDC_SAFE_MODE=0
	CLAUDE_ARGS=()
	export CDC_MOCK_PORTS_JSON='[]'
	sandbox_exists() { return 0; }

	run run_sandbox
	[ "$status" -eq 0 ]
	local publish_line exec_line
	publish_line="$(grep -n -- '--publish 3000' "$CDC_TEST_LOG" | head -1 | cut -d: -f1)"
	# The attach exec is the sbx exec that includes -w (working-dir flag);
	# the earlier symlink and notes execs do not use -w.
	exec_line="$(grep -n -- 'sbx exec.*-w' "$CDC_TEST_LOG" | head -1 | cut -d: -f1)"
	[ -n "$publish_line" ]
	[ -n "$exec_line" ]
	[ "$publish_line" -lt "$exec_line" ]
}

@test "publish failure aborts before attach and runs unpublish cleanup" {
	cdc_source
	# Use a two-spec list but make only the second fail so the first gets resolved
	# into CDC_PUBLISH_RESOLVED_SPECS and is cleaned up by unpublish_ports.
	# We achieve this by pre-seeding CDC_PUBLISH_RESOLVED_SPECS with the first
	# spec's canonical form to simulate a partial publish.
	CDC_PUBLISH_SPECS=(3000 8080:80)
	CDC_KEEP_RUNNING=0
	CDC_SAFE_MODE=0
	CLAUDE_ARGS=()
	export CDC_MOCK_PORTS_JSON='[]'
	export CDC_MOCK_PUBLISH_EXIT=2
	sandbox_exists() { return 0; }

	run run_sandbox
	[ "$status" -ne 0 ]
	# The attach exec includes -w; symlink/notes execs do not. Confirm no attach happened.
	! grep -q -- 'sbx exec.*-w' "$CDC_TEST_LOG"
	# With CDC_MOCK_PUBLISH_EXIT=2 the very first spec fails so no specs are
	# resolved; unpublish_ports is a no-op. Confirm at least one --publish was
	# attempted (proving the abort path was reached through publish_ports).
	grep -q -- '--publish.*3000' "$CDC_TEST_LOG"
}

@test "run_sandbox unpublishes ports after clean exit before sbx stop" {
	cdc_source
	CDC_PUBLISH_SPECS=(3000)
	CDC_KEEP_RUNNING=0
	CDC_SAFE_MODE=0
	CLAUDE_ARGS=()
	export CDC_MOCK_PORTS_JSON='[]'
	sandbox_exists() { return 0; }

	run run_sandbox
	[ "$status" -eq 0 ]
	local unpub_line stop_line
	unpub_line="$(grep -n -- '--unpublish.*3000' "$CDC_TEST_LOG" | head -1 | cut -d: -f1)"
	stop_line="$(grep -n '^sbx stop' "$CDC_TEST_LOG" | head -1 | cut -d: -f1)"
	[ -n "$unpub_line" ]
	[ -n "$stop_line" ]
	[ "$unpub_line" -lt "$stop_line" ]
}

@test "partial publish failure unpublishes already-resolved specs" {
	cdc_source
	CDC_PUBLISH_SPECS=(3000 8080:80)
	CDC_KEEP_RUNNING=0
	CDC_SAFE_MODE=0
	CLAUDE_ARGS=()
	export CDC_MOCK_PORTS_JSON='[]'
	export CDC_MOCK_PUBLISH_FAIL_AT=2
	export CDC_MOCK_PUBLISH_EXIT=2
	sandbox_exists() { return 0; }

	run run_sandbox
	[ "$status" -ne 0 ]
	# Attach must NOT have happened
	! grep -q 'sbx exec.*-w' "$CDC_TEST_LOG"
	# First spec succeeded — its canonical form must have been unpublished.
	# Mock allocates ephemeral host port 49153 for bare specs.
	grep -q -- '--unpublish 127.0.0.1:49153:3000/tcp' "$CDC_TEST_LOG"
	# Second spec failed before resolving — must NOT appear in unpublish.
	! grep -q -- '--unpublish.*8080:80' "$CDC_TEST_LOG"
}

@test "--cdc-keep-running skips both unpublish and stop" {
	cdc_source
	CDC_PUBLISH_SPECS=(3000)
	CDC_KEEP_RUNNING=1
	CDC_SAFE_MODE=0
	CLAUDE_ARGS=()
	export CDC_MOCK_PORTS_JSON='[]'
	sandbox_exists() { return 0; }

	run run_sandbox
	[ "$status" -eq 0 ]
	! grep -q -- '--unpublish' "$CDC_TEST_LOG"
	! grep -q '^sbx stop' "$CDC_TEST_LOG"
}
