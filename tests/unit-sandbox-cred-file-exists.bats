#!/usr/bin/env bats
load helpers/setup

setup() { cdc_setup; cdc_source; }
teardown() { cdc_teardown; }

@test "returns 0 when sbx exec test -s succeeds" {
	export CDC_TEST_MOCK_SBX_EXIT=0
	run sandbox_cred_file_exists my-sandbox
	[ "$status" -eq 0 ]
}

@test "returns non-zero when sbx exec test -s fails" {
	# Override mock-sbx with one that exits 1 for exec, to simulate missing creds.
	cat >"$CDC_TEST_DIR/bin/sbx" <<'S'
#!/usr/bin/env bash
: "${CDC_TEST_LOG:=/tmp/cdc-test-log}"
{ printf 'sbx'; for a in "$@"; do printf ' %q' "$a"; done; printf '\n'; } >>"$CDC_TEST_LOG"
exit 1
S
	chmod +x "$CDC_TEST_DIR/bin/sbx"
	run sandbox_cred_file_exists my-sandbox
	[ "$status" -ne 0 ]
}

@test "invokes sbx exec with test -s on /home/agent/.claude/.credentials.json" {
	sandbox_cred_file_exists my-sandbox || true
	run cat "$CDC_TEST_LOG"
	[[ "$output" == *"sbx exec my-sandbox test -s /home/agent/.claude/.credentials.json"* ]]
}
