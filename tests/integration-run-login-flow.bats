#!/usr/bin/env bats
load helpers/setup

setup() {
	cdc_setup
	cdc_source

	# Replace mock sbx with one that can emit configured stdout for login.
	cat >"$CDC_TEST_DIR/bin/sbx" <<'MOCK'
#!/usr/bin/env bash
set -uo pipefail
: "${CDC_TEST_LOG:=/tmp/cdc-test-log}"
: "${CDC_TEST_MOCK_SBX_EXIT:=0}"
: "${CDC_TEST_MOCK_SBX_STDOUT:=}"

{
	printf 'sbx'
	for arg in "$@"; do
		printf ' %q' "$arg"
	done
	printf '\n'
} >>"$CDC_TEST_LOG"

if [[ -n "$CDC_TEST_MOCK_SBX_STDOUT" ]]; then
	printf '%s\n' "$CDC_TEST_MOCK_SBX_STDOUT"
	sleep 0.1
fi

exit "$CDC_TEST_MOCK_SBX_EXIT"
MOCK
	chmod +x "$CDC_TEST_DIR/bin/sbx"
	export -f extract_oauth_url
}
teardown() { cdc_teardown; }

@test "run_login_flow runs sbx exec claude auth login" {
	export CDC_TEST_MOCK_SBX_STDOUT="Visit: https://claude.com/cai/oauth/authorize?x=1"
	run_login_flow my-sandbox
	grep -q 'claude auth login' "$CDC_TEST_LOG"
}

@test "run_login_flow invokes open with the detected URL" {
	export CDC_TEST_MOCK_SBX_STDOUT="Visit: https://claude.com/cai/oauth/authorize?x=abc"
	run_login_flow my-sandbox
	grep -q 'open https://claude.com/cai/oauth/authorize?x=abc' "$CDC_TEST_LOG"
}

@test "run_login_flow returns non-zero when sbx exec fails" {
	export CDC_TEST_MOCK_SBX_EXIT=1
	export CDC_TEST_MOCK_SBX_STDOUT=""
	run run_login_flow my-sandbox
	[ "$status" -ne 0 ]
}

@test "run_login_flow succeeds even when URL is not detected" {
	export CDC_TEST_MOCK_SBX_EXIT=0
	export CDC_TEST_MOCK_SBX_STDOUT="Unusual output with no URL"
	run run_login_flow my-sandbox
	[ "$status" -eq 0 ]
	! grep -q '^open ' "$CDC_TEST_LOG"
}

