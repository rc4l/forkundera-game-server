#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 rc4l

# [rc4l] Stand up a ForkUnderA server on this box. Nothing to edit, here or afterwards.
#
#   curl -fsSL https://raw.githubusercontent.com/rc4l/forkundera-game-server/main/host.sh | sudo bash -s duel40
#
# Re-running upgrades in place and keeps the WAD store. Adding a second server is the same command
# with a different --port.
#
# WHAT THIS DELIBERATELY IS NOT. It is a bootstrapper, not a configuration tool. Everything about what
# a server PLAYS lives in its catalogue entry, which is data the image already carries or that you drop
# in a volume; everything about how it RUNS is a flag below. The moment this script starts asking
# questions it has become the web panel nobody wanted.
set -euo pipefail

IMAGE="${FUA_IMAGE:-ghcr.io/rc4l/forkundera-game-server:latest}"
ROOT="${FUA_ROOT:-/opt/forkundera-game-server}"

# [rc4l] ONE volume for every server on the box, and this is the whole reason ten servers cost what
# one costs on disk. The image stores downloads content-addressed (by-md5/<digest>/<name>), so a 200 MB
# mod fetched for the first server is already present for the other nine, and nothing can clobber
# anything else. A per-instance volume would re-download the same file for every server that wants it.
VOLUME="${FUA_VOLUME:-forkundera-wads}"

ENTRY=""
VARIANT=""
PORT=10666
NAME=""
# [rc4l] EMPTY, not 8. FUA_PLAYERS becomes a +cvar the engine applies after the server's own cfg, so
# a default here silently overrules a server.cfg asking for 64 and the cfg looks broken. Unset means
# "say nothing", which lets the cfg decide. The entrypoint documents the same rule; defaulting it
# here defeated it. Pass --players only to override a cfg on purpose.
PLAYERS=""
RCON=""
PASSWORD=""
REGISTRY=""
ANNOUNCE=1

usage() {
	cat <<'USAGE'
Usage: host.sh [<entry>] [options]

  no arguments         deploy every folder under servers/ -- see below
  <entry>              catalogue id to host, e.g. duel40

  --variant ID         which way to play the entry (its default if omitted)
  --port N             UDP+TCP port (default 10666). A second server needs a different one.
  --name "..."         server name shown in the browser
  --players N          player limit (default 8)
  --rcon SECRET        remote admin password
  --password SECRET    password required to join
  --registry HOST      announce to a different server registry
  --private            do not announce at all
  --image REF          override the container image

A server folder holds exactly two files:

  servers/myserver/server.cfg    how it plays -- every cvar, sv_hostname included
  servers/myserver/wads.txt      what to load, in order:

                                     iwad doom2.wad
                                     file mymod.pk3

Ports are assigned from 10666 upward and REMEMBERED, so adding a folder never moves a server that
already exists. Put the wads themselves where the store lives; folder mode never downloads, because
without a hash there is nothing to check a download against.

Run it again with a different --port to add another catalogue server. Run it again with the SAME
port to upgrade that one in place.
USAGE
}

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==> %s\033[0m\n' "$*" >&2; exit 1; }

case "${1-}" in -h|--help) usage; exit 0 ;; esac

# [rc4l] No arguments means the servers/ folder decides. Each folder there is one server, and adding
# one is dropping in two files rather than remembering a command line.
if [ $# -eq 0 ]; then
	SCAN_SERVERS=1
else
	SCAN_SERVERS=0
	ENTRY="$1"; shift
fi

while [ $# -gt 0 ]; do
	case "$1" in
		--variant)  VARIANT="${2:?--variant needs a value}"; shift 2 ;;
		--port)     PORT="${2:?--port needs a value}"; shift 2 ;;
		--name)     NAME="${2:?--name needs a value}"; shift 2 ;;
		--players)  PLAYERS="${2:?--players needs a value}"; shift 2 ;;
		--rcon)     RCON="${2:?--rcon needs a value}"; shift 2 ;;
		--password) PASSWORD="${2:?--password needs a value}"; shift 2 ;;
		--registry) REGISTRY="${2:?--registry needs a value}"; shift 2 ;;
		--image)    IMAGE="${2:?--image needs a value}"; shift 2 ;;
		--private)  ANNOUNCE=0; shift ;;
		-h|--help)  usage; exit 0 ;;
		*)          die "unknown option: $1" ;;
	esac
done

case "${PORT}" in ''|*[!0-9]*) die "--port must be a number" ;; esac
[ "${PORT}" -ge 1024 ] && [ "${PORT}" -le 65535 ] || die "--port must be between 1024 and 65535"

[ "$(id -u)" -eq 0 ] || die "run this as root (it writes ${ROOT}, opens a firewall port and talks to docker)"

if [ "${SCAN_SERVERS}" -eq 1 ]; then
	SERVERS_DIR="${ROOT}/servers"
	mkdir -p "${SERVERS_DIR}"

	shopt -s nullglob
	folders=( "${SERVERS_DIR}"/*/ )
	shopt -u nullglob
	[ "${#folders[@]}" -gt 0 ] || die "no server folders in ${SERVERS_DIR} -- make one holding server.cfg and wads.txt"

	# [rc4l] VERIFY EVERYTHING BEFORE STARTING ANYTHING. One bad folder should not leave half a fleet
	# up and the operator guessing which half.
	for d in "${folders[@]}"; do
		name="$(basename "${d}")"
		[ -f "${d}server.cfg" ] || die "${name}: no server.cfg"
		[ -f "${d}wads.txt" ]   || die "${name}: no wads.txt"
		grep -qE "^[[:space:]]*iwad[[:space:]]+[^[:space:]]" "${d}wads.txt" 			|| die "${name}: wads.txt names no iwad, and a server cannot start without one"
	done

	# [rc4l] A folder that already has an instance KEEPS ITS PORT. If ports came from list position,
	# adding a folder would shift every server after it -- silently changing addresses people have
	# bookmarked, and making the registry treat them as new servers.
	assigned=""
	for d in "${folders[@]}"; do
		name="$(basename "${d}")"
		existing="$(ls -d "${ROOT}/instances/${name}-"* 2>/dev/null | head -1 || true)"
		if [ -n "${existing}" ]; then
			assigned="${assigned} ${name}:${existing##*-}"
		fi
	done

	# [rc4l] EVERY port already spoken for, not just the folders'. The first version only avoided
	# ports held by other folders and handed 10666 to a new folder while a catalogue server was
	# already listening on it -- a collision that surfaces as one server silently failing to bind.
	taken=""
	if [ -d "${ROOT}/instances" ]; then
		for inst in "${ROOT}/instances"/*/; do
			[ -d "${inst}" ] || continue
			p="$(basename "${inst}")"; p="${p##*-}"
			case "${p}" in ''|*[!0-9]*) continue ;; esac
			taken="${taken} ${p}"
		done
	fi

	next=10666
	for d in "${folders[@]}"; do
		name="$(basename "${d}")"
		port="$(printf '%s' "${assigned}" | tr ' ' '
' | grep "^${name}:" | cut -d: -f2 || true)"
		if [ -z "${port}" ]; then
			# [rc4l] Pad BOTH sides of every entry. Without a leading space the first port in the list
			# never matched its own search, so the collision check passed on exactly the port most
			# likely to be taken.
			while printf ' %s ' ${taken} | grep -q " ${next} "; do
				next=$(( next + 1 ))
			done
			port="${next}"
			assigned="${assigned} ${name}:${port}"
			taken="${taken} ${port}"
			next=$(( next + 1 ))
		fi
		log "servers/${name} -> port ${port}"
		# [rc4l] Re-invoke through bash rather than executing $0, which assumes this file carries the
		# execute bit. It often does not: the documented install is curl into /tmp and `bash host.sh`,
		# and that path failed with "Permission denied" the first time a folder deployed.
		FUA_SERVER_FOLDER="${name}" bash "$0" "__folder__${name}" --port "${port}" ${NAME:+--name "${NAME}"} || die "servers/${name} failed"
	done
	log "all ${#folders[@]} server folder(s) deployed"
	exit 0
fi

# [rc4l] A folder-mode instance is named for its folder; the entry id is a marker the scan passes back
# to this same script so there is one place that writes a compose file.
case "${ENTRY}" in
	__folder__*)
		SERVER_FOLDER="${ENTRY#__folder__}"
		INSTANCE="${SERVER_FOLDER}-${PORT}"
		;;
	*)
		SERVER_FOLDER=""
		INSTANCE="${ENTRY}${VARIANT:+-${VARIANT}}-${PORT}"
		;;
esac
DIR="${ROOT}/instances/${INSTANCE}"

#---------------------------------------------------------------------------------------------------
# Docker
#---------------------------------------------------------------------------------------------------

if ! command -v docker >/dev/null 2>&1; then
	log "installing docker"
	curl -fsSL https://get.docker.com | sh
fi

# [rc4l] `docker compose` (plugin) on anything current, `docker-compose` on older boxes. Checked rather
# than assumed, because the failure is otherwise a confusing "unknown command" halfway through setup.
if docker compose version >/dev/null 2>&1; then
	COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
	COMPOSE="docker-compose"
else
	die "no docker compose available; install the compose plugin"
fi

docker volume inspect "${VOLUME}" >/dev/null 2>&1 || {
	log "creating shared WAD volume ${VOLUME}"
	docker volume create "${VOLUME}" >/dev/null
}

#---------------------------------------------------------------------------------------------------
# The compose file
#---------------------------------------------------------------------------------------------------

mkdir -p "${DIR}"

{
	echo "# Generated by host.sh. Re-running the script rewrites this file."
	echo "# Edit it if you like -- but the script is the supported way, and it will overwrite you."
	echo "services:"
	echo "  server:"
	echo "    image: ${IMAGE}"
	echo "    container_name: fua-${INSTANCE}"
	# [rc4l] HOST NETWORKING, and it is not a preference.
	#
	# The registry lists a server at the source address AND PORT of its own announce packet
	# (server-registry/main.cpp: newServer.Address = AddressFrom). Behind a bridge network the announce
	# leaves masqueraded, so the registry publishes an address nothing is listening on -- intermittently,
	# because NAT usually but not always preserves the port, which is worse than never working.
	#
	# Inbound matters just as much: sv_maxclientsperip defaults to 2 and both server bans and the
	# registry's pushed ban list match on client address, so a bridge that rewrites every client to the
	# gateway caps the server at two players and breaks every ban at once.
	echo "    network_mode: host"
	echo "    restart: unless-stopped"
	echo "    stop_grace_period: 30s"
	echo "    volumes:"
	echo "      - ${VOLUME}:/data"
	# [rc4l] Read-only: the server has no business writing to your server definitions.
	[ -d "${ROOT}/servers" ] && echo "      - ${ROOT}/servers:/data/servers:ro"
	echo "    environment:"
	if [ -n "${SERVER_FOLDER}" ]; then
		echo "      FUA_SERVER_DIR: \"/data/servers/${SERVER_FOLDER}\""
	else
		echo "      FUA_ENTRY: \"${ENTRY}\""
	fi
	echo "      FUA_PORT: \"${PORT}\""
	if [ -n "${PLAYERS}" ]; then
		echo "      FUA_PLAYERS: \"${PLAYERS}\""
	fi
	echo "      FUA_ANNOUNCE: \"${ANNOUNCE}\""
	[ -n "${VARIANT}" ]  && echo "      FUA_VARIANT: \"${VARIANT}\""
	[ -n "${NAME}" ]     && echo "      FUA_NAME: \"${NAME}\""
	[ -n "${RCON}" ]     && echo "      FUA_RCON: \"${RCON}\""
	[ -n "${PASSWORD}" ] && echo "      FUA_PASSWORD: \"${PASSWORD}\""
	[ -n "${REGISTRY}" ] && echo "      FUA_REGISTRY: \"${REGISTRY}\""
	echo "    logging:"
	echo "      driver: json-file"
	echo "      options: { max-size: \"10m\", max-file: \"3\" }"
	echo "volumes:"
	echo "  ${VOLUME}:"
	echo "    external: true"
} > "${DIR}/docker-compose.yml"

# [rc4l] The generated file can carry an rcon or join password, so it is not world-readable.
chmod 600 "${DIR}/docker-compose.yml"

#---------------------------------------------------------------------------------------------------
# Firewall
#
# [rc4l] BOTH protocols, same number. UDP carries the game; TCP is the server handing joiners the WADs
# it runs. Opening only UDP is the failure that looks like success: the server works perfectly and
# every download from it fails.
#
# Only the HOST firewall is touched. A router in front of this box is not something a script inside it
# can reach or should pretend to, and the registry answers the reachability question for real further
# down by trying to reach us from outside.
#---------------------------------------------------------------------------------------------------

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then
	log "opening ${PORT}/udp and ${PORT}/tcp (ufw)"
	ufw allow "${PORT}/udp" >/dev/null || warn "could not add the ufw udp rule"
	ufw allow "${PORT}/tcp" >/dev/null || warn "could not add the ufw tcp rule"
elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
	log "opening ${PORT}/udp and ${PORT}/tcp (firewalld)"
	firewall-cmd --permanent --add-port="${PORT}/udp" >/dev/null || warn "could not add the firewalld udp rule"
	firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null || warn "could not add the firewalld tcp rule"
	firewall-cmd --reload >/dev/null || true
else
	warn "no active ufw or firewalld found; make sure ${PORT}/udp AND ${PORT}/tcp reach this box"
fi

#---------------------------------------------------------------------------------------------------
# Go
#---------------------------------------------------------------------------------------------------

log "pulling ${IMAGE}"
$COMPOSE -f "${DIR}/docker-compose.yml" pull -q 2>/dev/null || $COMPOSE -f "${DIR}/docker-compose.yml" pull

log "starting ${INSTANCE}"
# [rc4l] --force-recreate, always. Compose compares the COMPOSE FILE and leaves the container alone
# when it has not changed, which is the wrong question here: almost nothing this script exists to
# change lives in that file.
#
# The catalogue lives in the image, the WADs live in the shared volume, and the entry is re-resolved
# from both every time the entrypoint runs. So dropping doom2.wad into /data/wads and re-running with
# the same arguments did nothing at all -- four servers kept their substituted Freedoom, and the logs
# went on saying "substituted" while it looked like a successful deploy. It took a docker restart to
# apply, which is not something an operator should have to know.
#
# Recreating costs a few seconds of downtime on the one server named on the command line. Running this
# script is already an explicit act, and "I ran the deploy command and nothing happened" is the worse
# failure by a distance.
$COMPOSE -f "${DIR}/docker-compose.yml" up -d --force-recreate

#---------------------------------------------------------------------------------------------------
# Say what happened
#
# [rc4l] Reachability is REPORTED, never predicted. A machine cannot tell from the inside whether its
# port is forwarded -- checking your own port proves only that you can talk to yourself. The registry
# runs the one test that counts, by sending an unsolicited packet from outside and refusing to list a
# server that does not answer, so waiting a few seconds and reading the log is a real answer where a
# local probe would be theatre.
#---------------------------------------------------------------------------------------------------

log "waiting for the server to come up"
ready=0
for _ in $(seq 1 30); do
	if docker logs "fua-${INSTANCE}" 2>&1 | grep -q "UDP Initialized"; then ready=1; break; fi
	if [ "$(docker inspect -f '{{.State.Running}}' "fua-${INSTANCE}" 2>/dev/null)" != "true" ]; then break; fi
	sleep 2
done

echo
if [ "$ready" -ne 1 ]; then
	warn "the server did not report a bound socket. Its log:"
	docker logs --tail 40 "fua-${INSTANCE}" 2>&1 || true
	die "start failed"
fi

ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo "<this box>")"

log "up: ${ip}:${PORT}"
docker logs "fua-${INSTANCE}" 2>&1 | grep -E "^\*\*\*|WAD serving enabled" | tail -3 || true

cat <<EOF

  instance   ${INSTANCE}
  compose    ${DIR}/docker-compose.yml
  logs       docker logs -f fua-${INSTANCE}
  stop       ${COMPOSE} -f ${DIR}/docker-compose.yml down
  add one    host.sh <entry> --port $((PORT + 1))

EOF

if [ "${ANNOUNCE}" = "1" ]; then
	log "announced to the registry. Whether the internet can actually reach you is decided out there,"
	log "not in here: the registry replies from outside and will not list a server that never answers."
	log "Watch for it:  docker logs -f fua-${INSTANCE}"
fi
