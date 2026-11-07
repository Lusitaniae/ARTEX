#!/bin/sh
# Docker entrypoint (container only; local installs use ./start.sh directly).
#
# The runtime user is uid 10001 (see Dockerfile), but docker-compose bind-mounts
# ./data and ./keys from the host, and the Docker daemon creates missing host
# directories as root:root. Without a handover the unprivileged user cannot write
# the SQLite/task data or the JWT key, and artex exits on startup.
#
# So PID 1 starts as root, gives away *only* the two writable volumes, and then
# drops to uid 10001 before artex runs. /app/artex and /app/skills stay root-owned
# and read-only: a compromised agent process still cannot rewrite the binary or the
# skills, which is the property the unprivileged user exists for.
set -eu

APP_UID=10001
APP_GID=10001

if [ "$(id -u)" = "0" ]; then
	for d in /app/data /app/keys; do
		mkdir -p "$d"
		# Chown only entries that are not already ours (a `chown -R` on every start
		# would rewrite a large data/ tree on each container restart). -h keeps
		# symlinks themselves from being followed out of the volume.
		find "$d" \( ! -uid "$APP_UID" -o ! -gid "$APP_GID" \) \
			-exec chown -h "$APP_UID:$APP_GID" {} + 2>/dev/null || true
	done
	exec setpriv --reuid="$APP_UID" --regid="$APP_GID" --init-groups -- "$0" "$@"
fi

exec /app/start.sh "$@"
