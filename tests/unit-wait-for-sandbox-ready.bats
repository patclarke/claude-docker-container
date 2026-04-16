#!/usr/bin/env bats
load helpers/setup

setup() {
	cdc_setup
	cdc_source
	# Keep tests fast: override poll defaults so 30×0.5s → 5×0.01s
	export CDC_READY_POLL_MAX=5
	export CDC_READY_POLL_INTERVAL=0.01
}
teardown() { cdc_teardown; }

@test "returns 0 immediately when sbx exec succeeds" {
	cat >"$CDC_TEST_DIR/bin/sbx" <<'S'
#!/usr/bin/env bash
: "${CDC_TEST_LOG:=/tmp/cdc-test-log}"
{ printf 'sbx'; for a in "$@"; do printf ' %q' "$a"; done; printf '\n'; } >>"$CDC_TEST_LOG"
exit 0
S
	chmod +x "$CDC_TEST_DIR/bin/sbx"

	run wait_for_sandbox_ready my-sandbox
	[ "$status" -eq 0 ]

	# Should have made exactly one sbx exec true call.
	run grep -c 'sbx exec my-sandbox true' "$CDC_TEST_LOG"
	[ "$output" -eq 1 ]
}

@test "returns 0 after 137 eventually becomes 0" {
	local counter_file="$CDC_TEST_DIR/counter"
	echo 0 >"$counter_file"
	cat >"$CDC_TEST_DIR/bin/sbx" <<S
#!/usr/bin/env bash
: "\${CDC_TEST_LOG:=/tmp/cdc-test-log}"
{ printf 'sbx'; for a in "\$@"; do printf ' %q' "\$a"; done; printf '\\n'; } >>"\$CDC_TEST_LOG"
n=0
[ -f "$counter_file" ] && n=\$(cat "$counter_file")
n=\$((n + 1))
echo "\$n" >"$counter_file"
if [ "\$n" -lt 3 ]; then
	exit 137
fi
exit 0
S
	chmod +x "$CDC_TEST_DIR/bin/sbx"

	run wait_for_sandbox_ready my-sandbox
	[ "$status" -eq 0 ]

	# Should have made exactly 3 sbx exec true calls.
	run grep -c 'sbx exec my-sandbox true' "$CDC_TEST_LOG"
	[ "$output" -eq 3 ]
}

@test "returns non-zero after max consecutive 137s" {
	cat >"$CDC_TEST_DIR/bin/sbx" <<'S'
#!/usr/bin/env bash
: "${CDC_TEST_LOG:=/tmp/cdc-test-log}"
{ printf 'sbx'; for a in "$@"; do printf ' %q' "$a"; done; printf '\n'; } >>"$CDC_TEST_LOG"
exit 137
S
	chmod +x "$CDC_TEST_DIR/bin/sbx"

	run wait_for_sandbox_ready my-sandbox
	[ "$status" -ne 0 ]
}
