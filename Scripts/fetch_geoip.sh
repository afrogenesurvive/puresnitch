#!/usr/bin/env bash
#
# Downloads the DB-IP Lite IP-to-City database into Resources/GeoIP/.
#
# Why this exists: the city database is ~121 MB, which is larger than GitHub's
# 100 MB per-file limit, so it cannot be committed. It is fetched on demand and
# gitignored instead. Everything that builds a user-facing bundle must run this
# first - Scripts/build_snitch.sh does it automatically, and the CI build job
# has its own cached step.
#
# The database is licensed CC BY 4.0 by DB-IP.com. Attribution is a condition of
# that licence; see Resources/GeoIP/ATTRIBUTION.md, which IS committed.
#
# Usage:
#   Scripts/fetch_geoip.sh [--force] [--check]
#
#   --force   Re-download even when the installed file already matches.
#   --check   Verify the installed file only; never download.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Pinned so builds stay reproducible. Bumping is a deliberate act: change the
# release month and BOTH checksums together, taken from
# https://db-ip.com/db/download/ip-to-city-lite
#   File size 121.4 MB, 7,748,998 records (September 2026 release).
DBIP_RELEASE="2026-09"
DBIP_SHA1="6ea870a637b5460023643fc18fdea84dcea14b9c"
DBIP_MD5="8a0a03f5b9098ba9f2e28f920473d6c1"

# The published size is for the decompressed MMDB. Anything far below this is
# an error page or a truncated transfer, not a database.
DBIP_MIN_BYTES=$((50 * 1024 * 1024))

DB_NAME="dbip-city-lite.mmdb"
DEST_DIR="$ROOT/Resources/GeoIP"
DEST="$DEST_DIR/$DB_NAME"
WORK_DIR="$ROOT/build/geoip-download"
URL="https://download.db-ip.com/free/dbip-city-lite-${DBIP_RELEASE}.mmdb.gz"

FORCE=0
CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --check) CHECK_ONLY=1 ;;
    -h|--help)
      echo "Usage: Scripts/fetch_geoip.sh [--force] [--check]"
      echo "  --force   Re-download even when the installed file already matches."
      echo "  --check   Verify the installed file only; never download."
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

sha1_of() { shasum -a 1 "$1" | awk '{print $1}'; }
md5_of() { md5 -q "$1"; }

# Echoes the reason the file is unusable, or nothing when it is good. Always
# returns 0 so callers branch on the message, never on the exit status.
verify_file() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "not present"
    return 0
  fi
  local size actual
  size="$(wc -c < "$file" | tr -d '[:space:]')"
  if [ "$size" -lt "$DBIP_MIN_BYTES" ]; then
    echo "only $size bytes - expected at least $DBIP_MIN_BYTES"
    return 0
  fi
  actual="$(sha1_of "$file")"
  if [ "$actual" != "$DBIP_SHA1" ]; then
    echo "SHA1 is $actual, expected $DBIP_SHA1"
    return 0
  fi
  actual="$(md5_of "$file")"
  if [ "$actual" != "$DBIP_MD5" ]; then
    echo "MD5 is $actual, expected $DBIP_MD5"
    return 0
  fi
  return 0
}

REASON=""
if [ -f "$DEST" ]; then
  REASON="$(verify_file "$DEST")"
  if [ -z "$REASON" ]; then
    if [ "$FORCE" = "0" ]; then
      echo ">> GeoIP database already installed and verified ($DBIP_RELEASE)"
      exit 0
    fi
    echo ">> --force given; re-downloading…"
  else
    echo ">> Installed database failed verification: $REASON"
    if [ "$CHECK_ONLY" = "1" ]; then
      fail "installed database is not usable - re-run Scripts/fetch_geoip.sh"
    fi
    echo ">> Re-downloading…"
  fi
fi

if [ "$CHECK_ONLY" = "1" ]; then
  fail "$DEST is missing or unverified - run Scripts/fetch_geoip.sh"
fi

mkdir -p "$DEST_DIR" "$WORK_DIR"
ARCHIVE="$WORK_DIR/dbip-city-lite-${DBIP_RELEASE}.mmdb.gz"
EXTRACTED="$WORK_DIR/$DB_NAME"

echo ">> Downloading DB-IP Lite IP-to-City ${DBIP_RELEASE} (about 40 MB compressed)…"
rm -f "$ARCHIVE" "$EXTRACTED"
# --fail so an HTTP error page fails the build instead of becoming "the database".
curl --fail --location --silent --show-error \
  --output "$ARCHIVE" \
  "$URL" || fail "download failed: $URL"

[ -f "$ARCHIVE" ] || fail "download produced no file at $ARCHIVE"

echo ">> Decompressing…"
gunzip -c "$ARCHIVE" > "$EXTRACTED" || fail "could not decompress $ARCHIVE"

echo ">> Verifying checksums…"
REASON="$(verify_file "$EXTRACTED")"
if [ -n "$REASON" ]; then
  fail "downloaded database failed verification: $REASON
This usually means DB-IP published a new release. Update DBIP_RELEASE, DBIP_SHA1
and DBIP_MD5 in Scripts/fetch_geoip.sh (checksums are listed next to the MMDB
download on https://db-ip.com/db/download/ip-to-city-lite)."
fi

# Install atomically so an interrupted run can never leave a half-written file
# that the helper would go on to memory-map.
# The braces matter: writing "$DB_NAME…" makes the shell read the ellipsis as
# part of the variable name, which fails under `set -u`.
echo ">> Installing to Resources/GeoIP/${DB_NAME}…"
mv -f "$EXTRACTED" "$DEST"
rm -f "$ARCHIVE"

echo ">> Done: $DEST"
echo "   Contains IP geolocation data by DB-IP (https://db-ip.com), CC BY 4.0."
