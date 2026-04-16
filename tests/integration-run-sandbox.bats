#!/usr/bin/env bats
load helpers/setup

setup() {
	cdc_setup
	cdc_source
}
teardown() { cdc_teardown; }

# Build a mock sbx that handles all subcommands run_sandbox needs.
# $1 — exit code for `test -s` (0 = creds exist, 1 = missing)
_write_mock_sbx() {
	local cred_check_exit="$1"
	cat >"$CDC_TEST_DIR/bin/sbx" <<S
#!/usr/bin/env bash
: "\${CDC_TEST_LOG:=/tmp/cdc-test-log}"
{ printf 'sbx'; for a in "\$@"; do printf ' %q' "\$a"; done; printf '\n'; } >>"\$CDC_TEST_LOG"
case "\$1" in
	ls) echo "my-sandbox" ;;
	exec)
		if printf '%s ' "\$@" | grep -q 'test -s'; then exit $cred_check_exit; fi
		if printf '%s ' "\$@" | grep -q 'claude auth login'; then
			echo "Visit: https://claude.com/cai/oauth/authorize?x=1"
			sleep 0.1
			exit 0
		fi
		exit 0
	;;
	stop) exit 0 ;;
esac
exit 0
S
	chmod +x "$CDC_TEST_DIR/bin/sbx"
}

@test "no-creds branch runs login flow before attach" {
	_write_mock_sbx 1  # cred file missing → run login flow
	export -f extract_oauth_url run_login_flow sandbox_cred_file_exists

	CDC_RESOLVED_MOUNTS=()
	CDC_KEEP_RUNNING=1
	CDC_SAFE_MODE=0
	CLAUDE_ARGS=()
	cd "$CDC_TEST_DIR"

	run_sandbox || true

	grep -q 'claude auth login' "$CDC_TEST_LOG"
}

@test "creds-exist branch skips login flow" {
	_write_mock_sbx 0  # cred file present → skip login flow
	export -f extract_oauth_url run_login_flow sandbox_cred_file_exists

	CDC_RESOLVED_MOUNTS=()
	CDC_KEEP_RUNNING=1
	CDC_SAFE_MODE=0
	CLAUDE_ARGS=()
	cd "$CDC_TEST_DIR"

	run_sandbox || true

	! grep -q 'claude auth login' "$CDC_TEST_LOG"
}

@test "bin/cdc contains no security find-generic-password calls" {
	local repo_root
	repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	! grep -n 'security find-generic-password' "$repo_root/bin/cdc"
}
