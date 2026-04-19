#!/usr/bin/env bats
load helpers/setup

setup() {
	cdc_setup
	cdc_source
	# build_sbx_argv needs these globals populated in cdc's normal flow.
	# Provide the minimum subset needed by the function under test.
	export CDC_SAFE_MODE=0
	CLAUDE_ARGS=()
	# Give compute_sandbox_name a cwd it can hash deterministically.
	cd "$CDC_TEST_DIR"
}
teardown() { cdc_teardown; }

# Helper — return the index of the first matching element in CDC_SBX_ARGV.
_argv_index_of() {
	local needle="$1"
	local i
	for i in "${!CDC_SBX_ARGV[@]}"; do
		if [[ "${CDC_SBX_ARGV[i]}" == "$needle" ]]; then
			printf '%s\n' "$i"
			return 0
		fi
	done
	return 1
}

@test "CDC_SBX_ARGV contains -e TERM=..." {
	build_sbx_argv
	local found=0 j
	for j in "${!CDC_SBX_ARGV[@]}"; do
		if [[ "${CDC_SBX_ARGV[j]}" == "-e" && "${CDC_SBX_ARGV[j+1]}" == TERM=* ]]; then
			found=1
			break
		fi
	done
	[ "$found" -eq 1 ]
}

@test "CDC_SBX_ARGV contains -e COLORTERM=..." {
	build_sbx_argv
	local found=0 j
	for j in "${!CDC_SBX_ARGV[@]}"; do
		if [[ "${CDC_SBX_ARGV[j]}" == "-e" && "${CDC_SBX_ARGV[j+1]}" == COLORTERM=* ]]; then
			found=1
			break
		fi
	done
	[ "$found" -eq 1 ]
}

@test "CDC_SBX_ARGV contains -e LANG=... and -e LC_ALL=..." {
	build_sbx_argv
	local lang_found=0 lcall_found=0 j
	for j in "${!CDC_SBX_ARGV[@]}"; do
		if [[ "${CDC_SBX_ARGV[j]}" == "-e" ]]; then
			[[ "${CDC_SBX_ARGV[j+1]}" == LANG=* ]] && lang_found=1
			[[ "${CDC_SBX_ARGV[j+1]}" == LC_ALL=* ]] && lcall_found=1
		fi
	done
	[ "$lang_found" -eq 1 ]
	[ "$lcall_found" -eq 1 ]
}

@test "CDC_SBX_ARGV contains -e TZ=<value> when TZ is exported" {
	export TZ="America/Denver"
	build_sbx_argv
	local found=0 j
	for j in "${!CDC_SBX_ARGV[@]}"; do
		if [[ "${CDC_SBX_ARGV[j]}" == "-e" && "${CDC_SBX_ARGV[j+1]}" == "TZ=America/Denver" ]]; then
			found=1
			break
		fi
	done
	[ "$found" -eq 1 ]
}

@test "all -e flags appear before the sandbox name" {
	build_sbx_argv
	local name
	name="$(compute_sandbox_name)"
	local name_idx last_e_idx=-1 j
	name_idx=$(_argv_index_of "$name")
	[ -n "$name_idx" ]
	for j in "${!CDC_SBX_ARGV[@]}"; do
		if [[ "${CDC_SBX_ARGV[j]}" == "-e" ]]; then
			last_e_idx=$j
		fi
	done
	[ "$last_e_idx" -lt "$name_idx" ]
}

@test "claude appears after the sandbox name" {
	build_sbx_argv
	local name
	name="$(compute_sandbox_name)"
	local name_idx claude_idx
	name_idx=$(_argv_index_of "$name")
	claude_idx=$(_argv_index_of "claude")
	[ -n "$name_idx" ]
	[ -n "$claude_idx" ]
	[ "$claude_idx" -gt "$name_idx" ]
}

@test "CDC_SBX_ARGV no longer contains the bare env wrapper" {
	build_sbx_argv
	local j has_env=0
	for j in "${!CDC_SBX_ARGV[@]}"; do
		if [[ "${CDC_SBX_ARGV[j]}" == "env" ]]; then
			has_env=1
			break
		fi
	done
	[ "$has_env" -eq 0 ]
}
