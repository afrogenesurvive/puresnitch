# GeoIP data attribution

PureSnitch performs IP geolocation entirely **on-device** using the DB-IP Lite
IP-to-City database. No IP address ever leaves the machine.

## Required attribution

This product includes IP geolocation data created by
[DB-IP](https://db-ip.com), available from <https://db-ip.com/db/lite/ip-to-city-lite>,
licensed under the [Creative Commons Attribution 4.0 International License](https://creativecommons.org/licenses/by/4.0/).

Attribution is a condition of that licence. It must remain visible to users —
the in-app credit lives in Settings › About.

## What is here

`dbip-city-lite.mmdb` is **not committed to this repository.** At 121.4 MB it
exceeds GitHub's 100 MB per-file limit, so it is fetched on demand into this
directory by `Scripts/fetch_geoip.sh` and gitignored. Only this file is tracked.

- Format: MMDB (MaxMind DB binary format), read directly by `Sources/Shared/MMDB.swift`
- Coverage: ~7.7 million IPv4/IPv6 ranges with country, region, city and approximate coordinates
- The database is a free "Lite" subset with reduced accuracy. Coordinates are
  city-level approximations, not server locations.

## Refreshing

The release month and both checksums are pinned in `Scripts/fetch_geoip.sh`.
To move to a newer release, update `DBIP_RELEASE`, `DBIP_SHA1` and `DBIP_MD5`
together — the values are published beside the MMDB download on
<https://db-ip.com/db/download/ip-to-city-lite>. The script refuses to install a
file whose checksums do not match, so a stale pin fails loudly rather than
silently shipping the wrong data.
