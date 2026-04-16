# shellcheck shell=bash
# Common bats helpers.

cdc_setup() {
	CDC_TEST_DIR="$(mktemp -d)"
	export CDC_TEST_DIR
	export CDC_TEST_LOG="$CDC_TEST_DIR/sbx.log"
	: >"$CDC_TEST_LOG"

	local repo_root
	repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	local bin_shim="$CDC_TEST_DIR/bin"
	mkdir -p "$bin_shim"
	ln -s "$repo_root/tests/helpers/mock-sbx" "$bin_shim/sbx"
	ln -s "$repo_root/tests/helpers/mock-open" "$bin_shim/open"
	export PATH="$bin_shim:$PATH"

	export HOME="$CDC_TEST_DIR/home"
	mkdir -p "$HOME/.config/cdc"
}

cdc_teardown() {
	rm -rf "$CDC_TEST_DIR"
}

cdc_log_line() {
	sed -n "${1}p" "$CDC_TEST_LOG"
}

cdc_source() {
	local repo_root
	repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	# shellcheck disable=SC1091
	source "$repo_root/bin/cdc"
}
