#!/usr/bin/env bash

##
# This script `push`es this repo from a checkout on a development machine to the server that does and serves the periodic builds, and can be used to `pull` the changes to the `keys`/`repo`/`apks` dirs back to commit them.
##

set -u #; set -x

baseDir=/app/lineage-build

cmd=${1:?} ; host=${2:?}
local=$( cd "$(dirname -- "$0")" ; pwd )/
remote=${host}:$baseDir/config/
shift 2 ; args=( "$@" )

case "$cmd" in
	push) sync=( --chmod=g+w,o-rwx --chown=lineage-build:lineage-build "$local" "$remote" ) ;;
	pull) sync=( --chmod=g-w,o-rwx                                     "$remote" "$local" ) ;;
	*) exit 1
esac

rsync \
--progress --checksum --inplace --no-whole-file \
--archive --delete --times \
--exclude='/.git' --exclude-from="$local"/'.gitignore' \
"${sync[@]}" "${args[@]}" || exit

if [[ $cmd == push ]] ; then
	nix run .'#'push-flake ssh://$host . || exit
fi
