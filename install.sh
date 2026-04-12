#!/usr/bin/env bash
#
# cdc installer — downloads bin/cdc and sets up PATH.
#
# Prerequisites (not handled by this script):
#   - Docker Desktop:  brew install --cask docker
#   - Claude Code:     https://claude.com/claude-code
#   - sbx:             brew install docker/tap/sbx && sbx login
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/patclarke/claude-docker-container/main/install.sh | bash
#
# https://github.com/patclarke/claude-docker-container

set -euo pipefail

CDC_URL="https://raw.githubusercontent.com/patclarke/claude-docker-container/main/bin/cdc"
INSTALL_DIR="$HOME/bin"
INSTALL_PATH="$INSTALL_DIR/cdc"

echo "cdc installer"
echo ""

# --- Step 1: download cdc ---------------------------------------------------

mkdir -p "$INSTALL_DIR"

echo "Downloading cdc to $INSTALL_PATH..."
if ! curl -fsSL "$CDC_URL" -o "$INSTALL_PATH"; then
	echo "ERROR: failed to download cdc. Check your network connection." >&2
	exit 1
fi
chmod +x "$INSTALL_PATH"
echo "  ✓ Downloaded cdc to $INSTALL_PATH"

# --- Step 2: add ~/bin to PATH ----------------------------------------------

SHELL_NAME="$(basename "${SHELL:-/bin/zsh}")"

case "$SHELL_NAME" in
zsh)
	RC_FILE="$HOME/.zshrc"
	;;
bash)
	if [[ "$(uname)" == "Darwin" ]]; then
		RC_FILE="$HOME/.bash_profile"
	else
		RC_FILE="$HOME/.bashrc"
	fi
	;;
*)
	echo ""
	echo "  ⚠️  Unknown shell: $SHELL_NAME"
	echo "  Add this to your shell config manually:"
	echo ""
	echo "    export PATH=\"\$HOME/bin:\$PATH\""
	echo ""
	echo "  Then open a new terminal and run: cdc --cdc-doctor"
	exit 0
	;;
esac

# Single quotes intentional: we want the literal string written to the
# rc file, not expanded at install time.
# shellcheck disable=SC2016
PATH_LINE='export PATH="$HOME/bin:$PATH"'

if grep -qF "$PATH_LINE" "$RC_FILE" 2>/dev/null; then
	echo "  ✓ ~/bin already on PATH in $RC_FILE"
else
	# Create the rc file if it doesn't exist (fresh macOS installs may not have .zshrc)
	touch "$RC_FILE"
	{
		echo ""
		echo "# Added by cdc installer (https://github.com/patclarke/claude-docker-container)"
		echo "$PATH_LINE"
	} >>"$RC_FILE"
	echo "  ✓ Added ~/bin to PATH in $RC_FILE"
fi

# --- Step 3: verify ---------------------------------------------------------

echo ""

# Add ~/bin to PATH for this session so we can run cdc right now
export PATH="$INSTALL_DIR:$PATH"

if command -v cdc >/dev/null 2>&1; then
	echo "Running cdc --cdc-doctor..."
	echo ""
	cdc --cdc-doctor || true
else
	echo "  ⚠️  cdc not found on PATH after install. This shouldn't happen."
	echo "  Try opening a new terminal and running: cdc --cdc-doctor"
fi

# --- Step 4: set sbx github secret from gh auth token -----------------------
#
# Without this, git over HTTPS and api.github.com requests from inside the
# sandbox fail silently. The token is stored in sbx's host-side proxy store,
# not injected into the sandbox filesystem, so agents inside the sandbox
# never see it directly.

if command -v sbx >/dev/null 2>&1 && command -v gh >/dev/null 2>&1; then
	if sbx secret list -g 2>/dev/null | awk '$2 == "github" {exit 0} END {exit 1}'; then
		: # already set; leave it alone
	elif gh_token="$(gh auth token 2>/dev/null)" && [[ -n "$gh_token" ]]; then
		echo ""
		echo "Setting sbx global secret 'github' from your gh auth token..."
		echo "  (Lets git push and curl api.github.com work inside cdc sandboxes."
		echo "   Stored in sbx's host-side proxy — the agent never sees the token.)"
		if sbx secret set -g github -t "$gh_token" >/dev/null 2>&1; then
			echo "  ✓ Set sbx global secret: github"
		else
			echo "  ⚠️  Failed to set secret. Run manually:"
			echo "       sbx secret set -g github -t \"\$(gh auth token)\""
		fi
		unset gh_token
	fi
fi

# --- Done --------------------------------------------------------------------

echo ""
echo "Install complete!"
echo ""
echo "  → To use cdc in this terminal right now, run:"
echo "    source $RC_FILE"
echo ""
echo "  Or just open a new terminal — PATH will be set automatically."
echo ""
echo "Prerequisites not handled by this script:"
echo "  - Docker Desktop:  brew install --cask docker"
echo "  - Claude Code:     https://claude.com/claude-code"
echo "  - sbx:             brew install docker/tap/sbx && sbx login"
echo ""
echo "Full setup guide: https://github.com/patclarke/claude-docker-container#install"
