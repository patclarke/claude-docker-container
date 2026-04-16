#!/usr/bin/env bats
load helpers/setup

setup() {
	cdc_setup
	cdc_source

	# Smart mock that returns configured stdout for `claude auth status --json`
	cat >"$CDC_TEST_DIR/bin/sbx" <<'MOCK'
#!/usr/bin/env bash
: "${CDC_TEST_LOG:=/tmp/cdc-test-log}"
: "${CDC_TEST_MOCK_AUTH_JSON:=}"

{ printf 'sbx'; for a in "$@"; do printf ' %q' "$a"; done; printf '\n'; } >>"$CDC_TEST_LOG"

# If this is a `claude auth status` call, return the configured JSON
if printf '%s ' "$@" | grep -q 'claude auth status'; then
	[[ -n "$CDC_TEST_MOCK_AUTH_JSON" ]] && printf '%s\n' "$CDC_TEST_MOCK_AUTH_JSON"
	exit 0
fi
exit 0
MOCK
	chmod +x "$CDC_TEST_DIR/bin/sbx"
}
teardown() { cdc_teardown; }

@test "returns 0 when subscriptionType is max" {
	export CDC_TEST_MOCK_AUTH_JSON='{"loggedIn":true,"subscriptionType":"max"}'
	run sandbox_has_subscription_auth my-sandbox
	[ "$status" -eq 0 ]
}

@test "returns 0 when subscriptionType is team" {
	export CDC_TEST_MOCK_AUTH_JSON='{"loggedIn":true,"subscriptionType":"team"}'
	run sandbox_has_subscription_auth my-sandbox
	[ "$status" -eq 0 ]
}

@test "returns non-zero when subscriptionType is null" {
	export CDC_TEST_MOCK_AUTH_JSON='{"loggedIn":true,"subscriptionType":null}'
	run sandbox_has_subscription_auth my-sandbox
	[ "$status" -ne 0 ]
}

@test "returns non-zero when subscriptionType is missing" {
	export CDC_TEST_MOCK_AUTH_JSON='{"loggedIn":false}'
	run sandbox_has_subscription_auth my-sandbox
	[ "$status" -ne 0 ]
}

@test "returns non-zero when sbx exec produces no output" {
	export CDC_TEST_MOCK_AUTH_JSON=""
	run sandbox_has_subscription_auth my-sandbox
	[ "$status" -ne 0 ]
}
