#!/bin/sh
# The remote part of git_serve (ADR-035): run this on the machine that tests the code.
#
#   mcp-pull.sh <url> <code> [target-folder]
#
# <url> and <code> come from the answer of the git_serve tool (http://host:port/repo.git and
# the 6 digits, good for about a minute).  The code goes out in a header of the one git
# command below and is not stored anywhere.  The folder (default: mcp-code) is made and
# turned into a git repository on first use; afterwards it holds exactly the served files.
# Prints the commit it now holds.  Needs git and base64.

set -e
url=$1
code=$2
dir=${3:-mcp-code}
[ -n "$url" ] && [ -n "$code" ] || { echo "usage: $0 <url> <code> [folder]" >&2; exit 2; }

mkdir -p "$dir"
cd "$dir"
[ -d .git ] || git init -q
auth=$(printf 'mcp:%s' "$code" | base64 | tr -d '\n')
git -c "http.extraHeader=Authorization: Basic $auth" fetch -q "$url" '+refs/mcp/snapshot:refs/mcp/snapshot' 2>/dev/null ||
git -c "http.extraHeader=Authorization: Basic $auth" fetch -q "$url" '+HEAD:refs/mcp/snapshot'
git checkout -q -f --detach refs/mcp/snapshot
git rev-parse HEAD
