# Architecture

## Process model

The shipping PureSnitch build uses two processes: the GUI and its privileged
helper. The optional Network System Extension is a separate, non-shipping build
flavour that requires Apple-issued provisioning profiles.

```
┌──────────────────────────────────────────────────────────────────────┐
│                          PureSnitch.app                              │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │                       PureSnitch (GUI)                         │  │
│  │  user-space, runs as the logged-in user                        │  │
│  │  Bundle: io.moamenbasel.puresnitch                             │  │
│  │  - SwiftUI views (Menubar, NetworkMonitor, AuditView, ...)     │  │
│  │  - HelperClient (NSXPCConnection over a Mach service)          │  │
│  │  - AppState (Observable, drives all views)                     │  │
│  └────────────────────────────┬───────────────────────────────────┘  │
│                               │ XPC                                  │
│  ┌────────────────────────────▼───────────────────────────────────┐  │
│  │                  PureSnitchHelper (daemon)                     │  │
│  │  root, registered with launchd via SMAppService.daemon         │  │
│  │  Bundle: io.moamenbasel.puresnitch.helper                      │  │
│  │  - PFManager     (root-only runtime anchor + pfctl)            │  │
│  │  - DNSProxy      (NWListener on UDP/TCP 53 + DoH upstream)     │  │
│  │  - NetMonitor    (parses nettop + lsof streams)                │  │
│  │  - BlocklistManager (fetches HOSTS-format lists, parses)       │  │
│  │  - RuleStore     (SQLite at /Library/Application Support/…)    │  │
│  │  - ProcessResolver (cached exec/cwd/bundle/cmdline)            │  │
│  │  - AudienceDiscovery (owner config → audiences)                │  │
│  │  - HelperService (NSXPCListenerDelegate)                       │  │
│  └────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
                               │
            ┌──────────────────┼────────────────────┐
            │           macOS kernel + tools         │
            │  pfctl(8)  ·  nettop(1)  ·  lsof(8)    │
            │  Network.framework  ·  dispatch  ·  …  │
            └────────────────────────────────────────┘
```

## Appearance and the menu-bar dropdown

Two GUI concerns that are easy to get wrong in ways that only surface at runtime.

**Theming.** `ThemeMode` (System / Light / Dark) lives in `AppState` and is
applied on *both* sides of the AppKit/SwiftUI boundary, because neither side
covers the other:

- `PSTheme` (`Sources/GUI/Views/Theme.swift`) builds every colour from
  `NSColor(name:dynamicProvider:)`, so the palette is a *dynamic* colour that
  re-resolves when the effective appearance changes. The `static let`
  declarations stay valid because no RGBA is frozen at startup.
- `AppState.applyTheme()` sets `NSApp.appearance`, which is what reaches window
  chrome, `NSMenu`, the panel background and the floating alert panel. The
  system mode must *assign* `nil` rather than skip the assignment, or a
  previously pinned appearance is never cleared.
- Each root view carries `.preferredColorScheme(state.themeMode.colorScheme)`,
  which is what makes the SwiftUI environment agree. A view that pins a literal
  scheme instead ignores the setting for its whole subtree.

**The dropdown is a panel, not a popover.** `NSPopover` cannot be resized by the
user — it accepts only a programmatic `contentSize`, and `NSHostingController`
fights even that by exporting the view's ideal size. `MenubarPanelController`
therefore anchors a borderless, non-activating `NSPanel` under the status item,
which buys real drag-to-resize, a remembered size and a minimum size. The cost is
that the dismissal behaviour `.transient` used to provide has to be arranged by
hand: Esc via `cancelOperation(_:)`, click-outside via global *and* local event
monitors, and app deactivation via `NSApplication.didResignActiveNotification`.
The status item's own window is exempted from the click monitor, because clicking
it toggles the panel and hiding first would make it close and immediately reopen.

The panel's SwiftUI root switches on `PopoverTab`. `Overview` is the original
popover contents; `Network`, `Rules` and `AI` render purpose-built mini views
from `MenubarTabs.swift`. The right-click menu, the header buttons and the
popover's own "…" buttons keep opening the full `NetworkMonitorView`,
`RulesManagerView` and `AuditView` windows — the tabs are a glance, never the
only route to a window.

## XPC contract

Defined in `Sources/Shared/HelperProtocol.swift`:

- **HelperProtocol** — GUI → Helper. Methods: `getStatus`, `setMode`, `addRule`, `removeRule`, `listRules`, `startMonitoring`, `installPF`, `refreshBlocklists`, `setDoHUpstream`, `listAudiences`, `addAudience`, `removeAudience`, `setAudienceEnabled`, `rediscoverAudiences`, `proxyExpectationReport`, etc.
- **HelperClientProtocol** — Helper → GUI. Methods: `notifyConnection`, `notifyTraffic`, `notifyAlert(connectionJSON, reply)`, `notifyLog`.

`notifyAlert` is currently used when the experimental DNS proxy evaluates an
`ask` rule. The GUI's `AppState.presentAlert(...)` puts up a SwiftUI sheet and
returns the Allow/Deny choice through the reply block. Passive connections found
by `lsof` are reported with `notifyConnection`; the shipping build does not
pause those sockets.

The helper accepts the first active console administrator as the owner of its
system-wide state. Every request is re-authorized against that owner and the
current administrator membership; release builds additionally require the
Developer ID-signed PureSnitch client. Desired enforcement and mode are stored
by the root helper and are authoritative after GUI or helper restarts. The
SQLite database, policy metadata, and PF state files are root-only.

## Experimental DNS path

```
manually configured client → loopback:53 (PureSnitch DNS proxy)
                                      │
                                      ├─ blocklist match? ──→ NXDOMAIN
                                      │
                                      ├─ rule says deny?  ──→ NXDOMAIN
                                      │
                                      ├─ rule says ask?   ──→ notifyAlert
                                      │                       │
                                      │                       ├─ allow ─→ DoH forward
                                      │                       └─ deny  ─→ NXDOMAIN
                                      │
                                      └─ default              ──→ DoH forward
```

Both UDP and TCP DNS are handled on loopback. DoH is an
`application/dns-message` POST to a single configurable HTTPS upstream.
PureSnitch does not intercept `libsystem_resolver`, modify network-service DNS
settings, or install the proxy as the macOS system resolver.

## pfctl path

When enforcement is enabled, PureSnitch first verifies that the active macOS
ruleset exposes the standard `com.apple/*` parent anchor. It then obtains its
own `pfctl -E` reference and loads the runtime sub-anchor
`com.apple/puresnitch`. The generated file is root-only at
`/Library/Application Support/PureSnitch/pf-anchor.conf`; PureSnitch does not
add declarations to or reload `/etc/pf.conf`.

The anchor file is rewritten by the helper from the enforceable subset of
`Rule[]` whenever rules change. Only enabled, unexpired, Default-profile,
host-wide deny rules are emitted. IP/CIDR rules are IPv4-only; domain,
per-process, allow, and non-default-profile rules are deliberately excluded:

```
block out quick proto { tcp udp } to 198.51.100.0/24
block in quick proto { tcp udp } from 203.0.113.7
block out quick proto { tcp udp } to any port 443
```

The helper stores only its own enable-reference token, releases it with
`pfctl -X`, and never disables global `pf`. Cleanup flushes only
`com.apple/puresnitch`. An exact legacy migration removes the two declarations
used by releases before v0.2.1 only after validating the candidate main ruleset.
The pre-migration `/etc/pf.conf.puresnitch.bak` is retained for manual recovery.

## Per-process observation

- `nettop -P -L 0 -x -J bytes_in,bytes_out -s 1` runs continuously. Each line update is parsed for process-level throughput which feeds the menubar histogram and Network Monitor process list.
- `lsof -i -n -P -F pcnPT` is polled every 2 s. Output is parsed into `Connection` records with PID, process path, transport, local/remote IP+port, and an inferred bundle ID (via Info.plist of the enclosing `.app`). A continuously observed socket keeps one database row; a gap starts a new session, and history is capped at the newest 5,000 rows. These snapshots do not carry per-connection byte totals. (v0.2.1 also performed no IP geolocation; locations are attributed on-device in the version in development - see below.)
- Process identity is enriched by `Helper/ProcessResolver.swift`, which caches the executable path, working directory, bundle ID and command line per PID. One cached lookup replaces a `/bin/ps` spawn per connection per poll.

## Geolocation (on-device)

Locations are resolved locally. There is no geolocation API call anywhere in the
codebase, and no observed address ever leaves the machine.

- The data is a DB-IP Lite IP-to-City `.mmdb` file (CC BY 4.0, attribution in
  Settings › About), read by `Sources/Shared/MMDB.swift` - a small vendored
  MaxMind-format reader. It is vendored rather than taken as a package because
  `Scripts/test_hardening.sh` compiles a fixed file list with `swiftc` and links
  only `-lsqlite3`, so a package graph would have to be taught to that script.
- At 121 MB the file exceeds GitHub's per-file limit, so it is **not committed**.
  `Scripts/fetch_geoip.sh` downloads it, verifies the pinned SHA1 and MD5, and
  installs `Resources/GeoIP/dbip-city-lite.mmdb`, which is gitignored. CI caches
  it, and the release scripts assert it is present in the signed bundle and in
  the DMG so a release cannot ship without it.
- The helper loads the file at startup and memory-maps it, so the cost is a
  mapping rather than a read of 121 MB. `ConnectionGeolocator` then stamps
  `country`, `countryCode`, `city`, `latitude` and `longitude` onto each
  snapshot, and an in-process cache keeps repeat lookups off the tree walk.
- Enrichment happens **after** `ActiveConnectionTracker.reconcile`. That order is
  load-bearing: `reconcile` rebuilds every `Connection` from the current
  observation and carries forward only `id`/`firstSeen`, so annotating earlier
  would discard every location on the next poll. A regression test asserts it.
- Private, loopback, link-local, CGNAT, multicast, ULA and documentation ranges
  are filtered before lookup, so LAN addresses never surface as places.
- `country`, `countryCode`, `latitude` and `longitude` were already present in
  the `connections` DDL, the `INSERT` and the `SELECT *` reader, so only the
  values were missing. `city` is new, and is appended **last** in both the DDL
  and `migrateConnectionColumns()` rather than beside the other geo columns: a
  `SELECT *` reader matches columns by position, so putting it anywhere else
  would silently shift every column after it instead of failing.
- `HelperStatus.geoLookupEnabled` and `geoDatabaseAvailable` drive a Settings
  toggle. The preference is a `geo_lookup_enabled` row in the helper's `settings`
  table and defaults to **on** when absent, because a local lookup needs nothing
  to be opted into first.
- A build without the database degrades to "no locations": the helper logs once
  and keeps monitoring. That is the state of every CI run and of a fresh clone
  before the fetch script is run.

`README.md`, `docs/README.*.md` and `docs/index.html` still describe the shipped
v0.2.1 release, which performs no geolocation at all.

## AI Activity audit (observation only)

The AI Activity window attributes observed connections to *audiences*: a client, a repository, an MCP server, or a service. Attribution never changes enforcement. `AudienceMode` is `observe` or `alert`, neither of which blocks, and it is deliberately not a `RuleAction` case, so audiences cannot reach `RuleMatcher` or the generated `pf` anchor.

- `Sources/Shared/Models.swift` defines `Audience`, `AudienceMatcher`, `AudienceKind`, `AudienceSource`, `AudienceMode` and `AudienceMatcherKind`.
- `Sources/Shared/AudienceMatcher.swift` holds `RepoLocator`, which walks up from a process working directory to the enclosing `.git` (at most 8 levels, cached), and `AudienceResolver`, which scores a connection against every enabled audience and annotates each snapshot in one pass so the rows stored by the helper and the rows pushed to the UI cannot disagree. A manual audience outranks a discovered one, then the longest matching pattern wins, then the audience name breaks ties.
- `Sources/Helper/AudienceDiscovery.swift` turns owner configuration into audiences and proxy declarations.
- `Sources/GUI/Views/AuditView.swift` renders the window and `AppState.refreshAudit()` drives it over the audience RPCs.

Matchers in different groups are OR'd, so an audience is the union of everything its groups name. Matchers sharing a non-nil `group` must all match, which is how "loopback host AND this port" is expressed without the host matcher alone swallowing every local connection. `commandLineContains` is what separates a plain `node` from a specific MCP server script, because `lsof` reports only the command name.

### Discovery runs as root

`AudienceDiscovery` runs inside the root helper but deliberately reads owner configuration. It resolves the owner's home from the claimed owner UID, falling back to the console user, rather than from `NSHomeDirectory()`, which would be root's home. It reads only from an allow-list and never writes:

- `~/Library/Application Support/Code/User`
- `~/.vscode-mcp-servers`
- `~/Documents/GitHub`
- `/Applications` and `~/Applications`
- `~/.config/opencode/opencode.jsonc`
- `~/.codex/config.toml`
- `~/.claude/settings.json`

Symlinks that escape the owner's home are refused, repository discovery stops at 200 repositories, and files above 1 MiB are skipped.

### Declaration versus observation

`ProxyDeclaration` records what a client *says* it will do: a base URL for a provider, never a credential, classified as `localProxy` (the recording proxy port), `localService` (another loopback service, such as a local model server) or `remoteEndpoint` (a provider reached directly). `ProxyExpectationBuilder` compares that declaration with the traffic actually observed and returns a `ProxyExpectationVerdict`: `proxied`, `bypassed`, `localEndpoint`, `idle` or `unattributed`. The report also lists `unproxiedAudiences`, audiences seen reaching remote hosts directly while nothing pointed them at a local proxy, which is derived from observation rather than declaration.

## Rule matching

`RuleMatcher.decision(for:rules:defaultMode:)` walks enabled, unexpired rules in `priority DESC` order. First match wins. No match = fall back to active mode (`alert` → `.ask`, `silentAllow` → `.allow`, `silentDeny` → `.deny`).

Host glob: `*.example.com`, `.example.com` both match.
IP CIDR: `10.0.0.0/8` matches anywhere in that block.
Process: bundle ID match wins; otherwise path prefix.

## NetExt — per-process firewall (Network System Extension)

`Sources/NetExt/FilterDataProvider.swift` is a `NEFilterDataProvider` content filter. It is built and embedded only by `project-netext.yml`; the shipping `project.yml` deliberately excludes it. With the required Apple-issued profiles, it provides per-process filtering using the same macOS mechanism as Little Snitch.

- `handleNewFlow` evaluates each socket flow with the shared `RuleMatcher`; allow → `.allow()`, deny → `.drop()`, ask → `.pause()` then resume with the user's verdict.
- App ↔ extension XPC: `Shared/IPCConnection.swift` (extension vends a mach service named by `NEMachServiceName`; the app connects and receives prompts, reusing the connection-alert UI).
- Rules reach the sandboxed extension via the app-group container (`Shared/SharedRuleBridge.swift`), mirrored by the GUI on every rule/mode change.
- Activation: `GUI/App/SystemExtensionManager.swift` (`OSSystemExtensionRequest` + `NEFilterManager`).

Shipping this separate flavour requires the `content-filter-provider-systemextension` entitlement, matching Developer ID provisioning profiles, signing + notarization, and the app installed in `/Applications`. See `Sources/NetExt/README.md`. The helper remains responsible for rule storage, `pf` rules, and the optional manual DNS proxy.
