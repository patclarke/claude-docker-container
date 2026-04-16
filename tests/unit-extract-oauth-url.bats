#!/usr/bin/env bats
load helpers/setup

setup() { cdc_setup; cdc_source; export -f extract_oauth_url; }
teardown() { cdc_teardown; }

@test "extracts URL from captured fixture" {
	local repo_root
	repo_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	run bash -c "extract_oauth_url < $repo_root/tests/fixtures/claude-auth-login.sample.txt"
	[ "$status" -eq 0 ]
	[[ "$output" == https://claude.com/cai/oauth/authorize* ]]
}

@test "extracts URL even with ANSI escapes around it" {
	local ansi
	ansi=$'\e[1mVisit: \e[0mhttps://claude.com/cai/oauth/authorize?x=1\e[0m trailing'
	run bash -c "printf '%s\n' \"\$1\" | extract_oauth_url" _ "$ansi"
	[ "$status" -eq 0 ]
	[ "$output" = "https://claude.com/cai/oauth/authorize?x=1" ]
}

@test "returns empty and exits non-zero when no URL present" {
	run bash -c 'printf "no url here\n" | extract_oauth_url'
	[ "$status" -ne 0 ]
	[ -z "$output" ]
}

@test "returns only the first URL if multiple are present" {
	run bash -c 'printf "https://claude.com/cai/oauth/authorize?a=1\nhttps://claude.com/cai/oauth/authorize?b=2\n" | extract_oauth_url'
	[ "$status" -eq 0 ]
	[ "$output" = "https://claude.com/cai/oauth/authorize?a=1" ]
}
