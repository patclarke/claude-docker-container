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

@test "run_login_flow publishes port bridge when claude listener is found" {
	cat >"$CDC_TEST_DIR/bin/sbx" <<'S'
#!/usr/bin/env bash
set -uo pipefail
: "${CDC_TEST_LOG:=/tmp/cdc-test-log}"
: "${CDC_TEST_MOCK_LISTEN_PORT:=34835}"

{ printf 'sbx'; for a in "$@"; do printf ' %q' "$a"; done; printf '\n'; } >>"$CDC_TEST_LOG"

case "$1" in
	exec)
		shift
		# Strip flags like -it or -i
		while [[ "${1:-}" == -* ]]; do shift; done
		shift  # sandbox name
		case "$1" in
			pkill) exit 0 ;;
			lsof)
				cat <<EOF
COMMAND   PID  USER FD   TYPE DEVICE SIZE/OFF NODE NAME
claude  14154 agent 13u  IPv6  11546      0t0  TCP [::1]:${CDC_TEST_MOCK_LISTEN_PORT} (LISTEN)
EOF
				exit 0 ;;
			sh) exit 0 ;;
			claude)
				echo "Opening browser to sign in"
				echo "If the browser didn't open, visit: https://claude.com/cai/oauth/authorize?x=1"
				sleep 1
				exit 0 ;;
		esac
		exit 0 ;;
	ports) exit 0 ;;
esac
exit 0
S
	chmod +x "$CDC_TEST_DIR/bin/sbx"
	export -f extract_oauth_url

	run_login_flow my-sandbox

	grep -q 'ports my-sandbox --publish 34835:34836' "$CDC_TEST_LOG"
}

@test "run_login_flow cleans up socat and unpublishes port on exit" {
	cat >"$CDC_TEST_DIR/bin/sbx" <<'S'
#!/usr/bin/env bash
set -uo pipefail
: "${CDC_TEST_LOG:=/tmp/cdc-test-log}"

{ printf 'sbx'; for a in "$@"; do printf ' %q' "$a"; done; printf '\n'; } >>"$CDC_TEST_LOG"

case "$1" in
	exec)
		shift
		while [[ "${1:-}" == -* ]]; do shift; done
		shift
		case "$1" in
			pkill) exit 0 ;;
			lsof)
				echo "claude 1 agent 13u IPv6 1 0 TCP [::1]:45000 (LISTEN)"
				exit 0 ;;
			sh) exit 0 ;;
			claude)
				echo "Visit: https://claude.com/cai/oauth/authorize?x=1"
				sleep 1
				exit 0 ;;
		esac
		exit 0 ;;
	ports) exit 0 ;;
esac
exit 0
S
	chmod +x "$CDC_TEST_DIR/bin/sbx"
	export -f extract_oauth_url

	run_login_flow my-sandbox

	grep -q 'ports my-sandbox --unpublish 45000:45001' "$CDC_TEST_LOG"
	grep -q 'pkill.*socat' "$CDC_TEST_LOG"
}

@test "run_login_flow works when lsof never finds claude (fallback to paste-back)" {
	cat >"$CDC_TEST_DIR/bin/sbx" <<'S'
#!/usr/bin/env bash
: "${CDC_TEST_LOG:=/tmp/cdc-test-log}"

{ printf 'sbx'; for a in "$@"; do printf ' %q' "$a"; done; printf '\n'; } >>"$CDC_TEST_LOG"

case "$1" in
	exec)
		shift
		while [[ "${1:-}" == -* ]]; do shift; done
		shift
		case "$1" in
			pkill) exit 0 ;;
			lsof) echo "COMMAND PID USER FD TYPE"; exit 0 ;;
			claude)
				echo "Visit: https://claude.com/cai/oauth/authorize?x=1"
				sleep 0.2
				exit 0 ;;
		esac
		exit 0 ;;
	ports) exit 0 ;;
esac
exit 0
S
	chmod +x "$CDC_TEST_DIR/bin/sbx"
	export -f extract_oauth_url

	export CDC_BRIDGE_POLL_INTERVAL=0.05
	export CDC_BRIDGE_POLL_MAX=5

	run run_login_flow my-sandbox
	[ "$status" -eq 0 ]
	! grep -q 'ports.*--publish' "$CDC_TEST_LOG"
}
