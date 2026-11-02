# Security and Failover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `executing-plans` to implement this plan task-by-task. Steps use checkbox syntax for tracking. Implementation is not authorized by the request to write this plan; obtain approval first.

**Goal:** Preserve VPN configurations during outages, prevent unintended direct proxy egress, and make the default installation private and reproducible.

**Architecture:** Retain AWG, microsocks, Privoxy and POSIX shell. Introduce a common candidate-selection cycle that commits failure penalties only after a replacement has actually become healthy. Separate proxy-client replies, explicitly permitted LAN destinations, and endpoint DNS resolution in the kill switch.

**Tech Stack:** Docker Compose, Alpine Linux, AmneziaWG userspace tooling, iproute2, iptables/ip6tables, POSIX shell, mocked shell tests and disposable Linux network namespaces.

**Spec:** The reviewed requirements and proposed design below are part of this plan. New environment-variable names and network-policy choices are proposals for approval, not previously agreed requirements.

## Scope and proposed design

Baseline inspected: local commit `5b41613` (`Add fail-closed outbound kill switch`). Existing untracked files (`AGENTS.md`, `.playwright-mcp/`, `session-ses_f4d8.md`) are not part of this work.

Approaches considered:

1. Minimal patches to individual failure branches: smaller diff, but leaves separate semantics for ranking, fast start and non-ranking mode and does not solve DNS isolation.
2. **Recommended:** unify failure accounting and harden the existing proxy stack. More tests and firewall work, but avoids a proxy migration and addresses the actual defects.
3. Replace the proxy stack and configuration-state system: potentially useful later, but too broad for these fixes.

Proposed behavior:

- Failed attempts remain pending within a selection cycle. Only successful activation of another candidate commits one strike per failed candidate. An entirely unsuccessful cycle discards pending strikes and waits; it does not claim to have diagnosed an Internet outage.
- Treat every nonzero `awg-quick up` result as inconclusive, not proof that the source file is invalid. Do not classify errors by matching diagnostic prose. Explicit local validation errors leave source files in place with a clear diagnostic and are not retried repeatedly within one cycle.
- Clear strikes for an active candidate only after three consecutive successful monitoring rounds, not merely one successful startup probe. This reuses `FAILOVER_FAILURES` and avoids introducing another tuning parameter.
- Publish proxies on `127.0.0.1` by default. LAN use requires an explicit bind and an explicit client-network configuration; unauthenticated public exposure remains unsupported.
- `LAN_NETWORK` and `LAN_NETWORK6` become exact allowlists for proxy destinations that may bypass the tunnel, empty by default. Remove all hidden private-network allowances.
- New `PROXY_CLIENT_NETWORKS` and `PROXY_CLIENT_NETWORKS6`, empty by default, specify remote client networks requiring return routes. They do not authorize proxy requests to those networks. Connected Docker-network return routes remain available without a broad LAN exemption.
- Permit direct TCP replies to inbound proxy connections with conntrack reply-direction matching and source-port restrictions. Never add a blanket `ESTABLISHED,RELATED` egress allowance.
- Block proxy-originated private/link-local destinations unless explicitly allowed, before the general `-o wg0` permit. IPv4 protected ranges: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`; IPv6: `fc00::/7`, `fe80::/10`, `ff00::/8`. Loopback remains permitted for internal proxy chaining. This policy covers these ranges, not every special-use address or every provider's metadata mechanism.
- Resolve endpoint hostnames in a bounded helper under a dedicated UID. DNS exceptions apply only to that UID and the configured resolvers; proxy processes must not share that UID. Stage numeric endpoints before running `awg-quick`, with DNS exceptions already closed. Literal IPv4 and bracketed IPv6 endpoints require no DNS exception.
- Keep `RANK_BUDGET=0` and `FAST_START=1`; document first-working/last-working semantics rather than promise a global fastest-server selection.

Out of scope: proxy authentication/migration, automatic failback, JSON status service, automatic restoration of existing quarantined files, WARP registration changes, GHCR publishing, multi-arch release automation, translated README, and production-server changes. Container capability removal/read-only filesystem are a separate compatibility-hardening follow-up, not unverified compose flags.

## Global constraints

- Do not read or print real `.conf` contents or `.env`; all test identities are synthetic.
- Do not run `proxy-checker` on real configuration directories: it can move files.
- Do not restart production containers, interrupt real tunnels, or register WARP devices.
- Container scripts remain POSIX `/bin/sh`; the host `proxy-checker` remains Bash.
- Keep `.strikes` and `.last_active` backwards-compatible; do not reset existing state.
- Source config files remain untouched during staging, resolution and validation.
- All firewall exceptions fail closed on setup or cleanup failure; no healthy marker survives a tunnel transition.
- Existing installations with `PROXY_BIND_ADDRESS=0.0.0.0` or broad LAN values retain those explicit settings until an operator changes them; document migration rather than silently rewrite `.env`.
- Work in an isolated worktree at execution time. Do not stage unrelated files. Each task is a separately reviewable commit.

## Review focus

- Fast start and `SPEED_TEST=0` must preserve files and strike counts over repeated all-candidate failures, including across manager restarts (Task 2).
- A failed selected candidate after successful ranking must not cause penalties to be committed using stale ranking evidence (Task 2).
- DNS through a private resolver, and an already-open DNS TCP connection, must not let proxy traffic bypass policy (Task 5).
- A permitted remote client must receive responses without gaining permission to request its router, neighboring containers or metadata (Task 4).
- Timeouts, termination and partial AWG startup must close DNS exceptions, remove readiness and leave no stray helper process (Tasks 3 and 5).

---

### Task 1: Safe publication and build-context isolation

**Files:** Modify `docker-compose.yml`, `.env.example`, `docs/SECURITY.md`, `docs/CONFIGURATION.md`; create `.dockerignore`, `tests/build-defaults-test.sh`.

**Interfaces:** Both published ports use `${PROXY_BIND_ADDRESS:-127.0.0.1}`. Build-context exclusions cover `config/`, `bad_config/`, `.env`, `.env.*` except `.env.example`, `.git/`, local session exports and browser artifacts.

- [ ] Add `test_default_bind_is_loopback`, `test_explicit_bind_is_preserved` and `test_secret_paths_are_excluded`. Inspect rendered compose JSON using a synthetic environment and a temporary empty env file, never the operator's `.env`.
- [ ] Run `sh tests/build-defaults-test.sh`; expect failure against the baseline public bind and missing ignore file.
- [ ] Change both compose defaults and `.env.example`; add exclusions without excluding `scripts/` or test/build inputs.
- [ ] Document that binding a specific interface limits exposure but is not a client ACL. For Docker's iptables backend explain `DOCKER-USER`, forwarding versus INPUT/UFW, and DNAT-aware matching. State that nftables backends need their corresponding forwarding policy, not a nonexistent `DOCKER-USER` chain.
- [ ] Run the test and `docker compose --env-file <empty-test-env> config --quiet`; expect success. Verify excluded synthetic secret files cannot be copied by a temporary context-inspection Dockerfile.
- [ ] Commit only this task's files: `security: default proxy publication to loopback and exclude secrets`.

### Task 2: Outage-safe selection and strike accounting

**Files:** Modify `scripts/failover-manager.sh`, `tests/failover-manager-test.sh`, `docs/FAILOVER.md`.

**Interfaces:** `start_tunnel(config)` retains statuses `0=started`, `1=candidate attempt failed`, `2=fatal local infrastructure failure`. Add `record_candidate_failure(path)`, `commit_pending_failures(active_path)`, `discard_pending_failures()` in the manager. Pending failures are deduplicated, newline-delimited paths in a private temporary file, not whitespace-separated strings or subshell-only variables. No pending state survives a manager restart.

- [ ] Add tests named `test_all_start_failures_preserve_configs`, `test_all_health_failures_preserve_strikes`, `test_replacement_activation_commits_one_strike`, `test_failed_activation_does_not_commit_rank_failures`, `test_single_config_never_quarantined_for_connectivity` and `test_flapping_config_keeps_strikes_until_stable`.
- [ ] Exercise all-failure cases for `SPEED_TEST=0`, `SPEED_TEST=1`, fast start, pre-existing strike count `QUARANTINE_AFTER-1`, and a manager restart. Assert original paths and contents survive, no new quarantine file appears, and persistent strike counts do not change.
- [ ] Run `sh tests/failover-manager-test.sh`; record the expected failures before implementation.
- [ ] Route ranking, activation and monitoring failures through the same pending-failure lifecycle. Commit only after a selected replacement passes its actual activation check, never just because a ranking probe once succeeded. Discard at the end of an unsuccessful complete cycle.
- [ ] On failover invalidate readiness immediately, queue the previous candidate last for the next complete cycle, and test alternatives before retrying it. If it is the only candidate, retry it after `CONFIG_POLL_INTERVAL`; do not skip it indefinitely.
- [ ] Defer `clear_strikes` until `FAILOVER_FAILURES` consecutive successful monitoring checks. Reset this stability counter on any failure or candidate transition; keep the existing consecutive-failure counter separate.
- [ ] Run the full mock suite; expect all tests to pass, updating old tests that asserted immediate quarantine to the new contract. Document evidence-based penalties and the fact that all-broken configurations are retained, not automatically diagnosed.
- [ ] Commit: `fix: preserve candidate configs during unconfirmed network failures`.

### Task 3: Bounded startup, valid measurements and truthful readiness

**Files:** Modify `scripts/failover-manager.sh`, `scripts/check-tunnel.sh`, `docker-compose.yml`, `.env.example`, `tests/failover-manager-test.sh`; create `tests/check-tunnel-test.sh`.

**Interfaces:** Add `AWG_UP_TIMEOUT=30` to compose/env/manager. `measure_latency()` prints a nonnegative integer milliseconds on at least one successful probe, otherwise prints nothing and returns nonzero. Unknown latency sorts as `999999`. Reject unsupported config input without moving the source file.

- [ ] Add tests for curl exit failure with plausible timings, empty/malformed timings, one valid sample among failures, unknown latency ranking last, and a startup process exceeding the timeout.
- [ ] Add tests for missing full IPv4 default `AllowedIPs`, marker removal during restart/switch/fatal exit, filenames containing spaces or backslashes, and signal cleanup in `check-tunnel.sh`. Explicitly reject filenames containing tabs or newlines with a clear diagnostic because ranking records use those delimiters.
- [ ] Run both test scripts; confirm each new regression is reproduced.
- [ ] Check curl exit status before consuming timings; reject invalid samples, retain best-of-three successful timing semantics, use literal newline/tab records and `printf '%s'` for paths. Replace word-splitting config loops with line-safe iteration without losing parent-shell state.
- [ ] Bound `awg-quick up` with the installed `timeout` implementation; clean partial interface state after timeout and reapply the kill switch before another attempt. Test child-process termination in the actual base image rather than assuming BusyBox timeout behavior.
- [ ] Validate full IPv4 tunnel support from actual `AllowedIPs` entries, not comments or substring matches such as `10.0.0.0/0`. Report unsupported split-tunnel configurations distinctly and leave them in place.
- [ ] Remove readiness before every down/restart and on termination; write it atomically only after successful activation. Give INT/TERM handlers explicit exits, and scope IFS changes in `check-tunnel.sh`.
- [ ] Run both mock suites and existing kill-switch mark tests. Verify Docker healthcheck timeout exceeds the worst-case sequential probe budget: with two eight-second probes use at least 20 seconds, and document that custom URL counts/timeouts require adjusting it.
- [ ] Commit: `fix: bound tunnel startup and reject invalid latency samples`.

### Task 4: Separate client replies from LAN destination permissions

**Files:** Modify `scripts/killswitch.sh`, `scripts/entrypoint.sh`, `docker-compose.yml`, `.env.example`, `tests/killswitch-test.sh`, `tests/killswitch-mark-test.sh`, `docs/SECURITY.md`, `docs/CONFIGURATION.md`.

**Interfaces:** Empty exact LAN destination allowlists; empty `PROXY_CLIENT_NETWORKS{,6}` return-route lists. Add a root-owned routing helper `scripts/proxy-routes.sh`, installed as `/proxy-routes.sh`, invoked by entrypoint before the first tunnel activation. It consumes captured Docker gateways and the four network-list variables, returning nonzero for invalid CIDRs or failed required routes. No client list becomes a blanket OUTPUT destination permit.

- [ ] Extend namespace tests with real local TCP listeners and client namespaces: default deny private/link-local destinations, explicit destination allow, permitted client responses, and denied fresh outbound connections to that same client's subnet. Include `169.254.169.254` and an adjacent Docker-subnet listener without contacting real metadata.
- [ ] Add rule-capture tests asserting removal of hidden base allowances, rejection before `-o wg0` for protected destinations, and absence of blanket established egress. Add malformed IPv4/IPv6 CIDR cases; reject bad configuration before applying routes/rules.
- [ ] Run mock tests and privileged namespace tests in a disposable Linux environment; confirm baseline failures.
- [ ] Implement rule ordering: loopback, narrowly matched TCP conntrack replies from proxy listening ports, explicit LAN destination permits, protected-range rejects, tunnel-interface permit, tunnel socket fwmark permit, final reject. Validate that reply matching cannot authorize an outbound connection's original direction.
- [ ] Install only explicit client/destination bypass routes before first tunnel startup, rather than after readiness. Verify routing remains correct through AWG down/up and with overlapping client/destination subnets; retain IPv4/IPv6 symmetry.
- [ ] Set compose and env LAN defaults empty. Use `${LAN_NETWORK-}` and corresponding unset-only expansion so an explicitly empty list stays empty. Document example narrow CIDRs, migration from old broad values, and that host bind is not an access-control list.
- [ ] Run `sh tests/killswitch-mark-test.sh`, `sh tests/failover-manager-test.sh`, and `sudo sh tests/killswitch-test.sh`. Require actual TCP request/response assertions, not only emitted-rule snapshots. Verify localhost-published access in an isolated Docker integration test.
- [ ] Commit: `security: separate proxy client replies from LAN egress permissions`.

### Task 5: Isolate endpoint DNS resolution

**Files:** Create `scripts/resolve-endpoint.sh`, `tests/resolve-endpoint-test.sh`; modify `Dockerfile`, `scripts/failover-manager.sh`, `scripts/killswitch.sh`, manager tests and namespace tests.

**Interfaces:** Install a dedicated non-login endpoint-resolver user with UID `65532`; no proxy runs under this UID. Install a bounded resolver utility and UID-switching helper explicitly in the image. `/resolve-endpoint.sh <hostname>` prints exactly one validated address, returns `0` on success, `1` on resolution failure, `2` on local infrastructure failure. Timeout is 10 seconds. It must not read private configuration files. `killswitch.sh dns-open` permits DNS only for this UID, never all processes.

- [ ] First run a bounded compatibility experiment in the pinned/test base: verify resolver output parsing, IPv4/IPv6 support, UID ownership matching and Docker's effective resolver path. If Docker DNS forwarding does not preserve the required isolation, stop this task for design review; do not fall back to container-wide DNS exceptions.
- [ ] Add parsing/staging tests for IPv4, bracketed IPv6, hostname plus port, multiple peers, malformed endpoint syntax, DNS failure and timeout. Assert only staged endpoints change and source bytes remain identical.
- [ ] Add real namespace DNS tests proving the helper UID can resolve during its window, proxy UID cannot, neither can after closure, a private resolver receives no hidden LAN exemption, and an existing DNS TCP stream cannot bypass closure. Exercise both UDP and TCP DNS.
- [ ] Run new tests to demonstrate the baseline leak and unbounded resolution behavior.
- [ ] Resolve each hostname before `awg-quick up`: open UID-scoped DNS, run the bounded helper, close DNS on every exit path, validate/substitute the numeric address, then start AWG. Numeric endpoints do not open DNS. No unresolved hostname fallback is allowed.
- [ ] Ensure endpoint DNS allowance is evaluated before protected-destination rejection only for the helper; keep proxy DNS subject to normal tunnel policy. Test IPv6 and the absence of an IPv6 default route explicitly.
- [ ] Test INT, TERM, resolver timeout, failed firewall finalization and partial AWG startup. Assert DNS is closed, readiness is absent, no helper remains and no config is quarantined merely for resolution failure. If closure fails, terminate proxy processes/container rather than leave service running under a temporary policy.
- [ ] Run resolver, manager, mark and namespace suites. Test failover while both proxies are actively receiving synthetic hostname requests, capturing the direct interface to prove no client DNS exits there.
- [ ] Commit: `security: isolate endpoint resolution from proxy DNS traffic`.

### Task 6: Pin and simplify the image without changing proxy behavior

**Files:** Modify `Dockerfile`; create `.github/renovate.json5`; update `docs/SECURITY.md`, `README.md`.

**Interfaces:** Base reference is `ghcr.io/mainfrezzer/amnezia-bridge@sha256:<verified-index-digest>`. Use a registry-verified manifest/index, never a guessed digest. Keep `/scripts` as the single script copy; compatibility paths under `/` are symlinks.

- [ ] Inspect the remote manifest and image in a disposable environment; record the chosen digest, available architectures, AWG/curl/timeout/resolver versions and upstream provenance. If no suitable manifest is available, stop and report the blocker rather than inventing a pin or architecture support.
- [ ] Add an image smoke test that checks `/entrypoint.sh`, `/failover-manager.sh`, `/killswitch.sh`, `/check-tunnel.sh`, `/ensure-tun.sh`, `/proxy-routes.sh`, `/resolve-endpoint.sh`, executable permissions and required utilities.
- [ ] Replace `latest` with the verified digest; remove duplicate COPY operations, create compatibility symlinks and combine related chmod/mkdir operations. Do not claim this pins Alpine package repositories or guarantees bit-for-bit reproducibility.
- [ ] Add Renovate configuration for Docker digest updates as reviewed PRs, without automerge. Explain that a pinned digest does not resolve missing upstream licensing.
- [ ] Inspect the bundled Privoxy configuration in the image, including forwarding, filtering and CONNECT restrictions. Smoke-test synthetic HTTP, HTTPS and CONNECT to a nonstandard local test port. Report intended restrictions; do not silently enable every CONNECT port or replace the proxy stack.
- [ ] Build with `docker compose --env-file <empty-test-env> config --quiet` followed by an isolated image build; run image smoke tests. Do not start the real compose service or mount real config directories.
- [ ] Commit: `build: pin upstream image and simplify script installation`.

### Task 7: Documentation, CI and final isolated acceptance

**Files:** Modify `README.md`, `.env.example`, `docs/CONFIGURATION.md`, `docs/FAILOVER.md`, `docs/SECURITY.md`, `docs/TROUBLESHOOTING.md`, `docs/PROXY_CHECKER.md`; create `.github/workflows/ci.yml` and a checked-in `tests/image-smoke-test.sh` if Task 6 has not already added it.

**Interfaces:** CI separates mock/static checks, Docker image smoke checks and privileged disposable namespace checks. No production secrets, WARP API calls or real VPN credentials are required.

- [ ] Add CI running every mocked shell suite, shell syntax checks, ShellCheck with explicit POSIX/Bash dialects and pinned tool versions, and Hadolint. Address findings relevant to changed code; document any narrow suppressions with reasons. Namespace jobs must fail rather than silently pass if their required prerequisites are unavailable.
- [ ] Run privileged namespace tests on a Linux runner with Python, iproute2, iptables and ping installed. Run image tests against the built artifact, not the developer host's utilities. Validate compose using a synthetic environment only.
- [ ] Remove all `DISABLE_TUNNEL_MODE` advice and dead compose/example comments. Correct claims about fastest selection, timing, permanent quarantine and external services: automatic health/latency probes contact configured health endpoints; GeoIP/IP-discovery APIs are checker behavior, not automatic manager behavior.
- [ ] Add upgrade instructions: existing `.env` overrides remain effective; broad LAN entries must be narrowed manually; restored quarantined configs require operator review. Document the optional authentication/migration and container-hardening work as not yet provided.
- [ ] Add a leak incident procedure limited to a disposable test container or explicit maintenance window: stop its tunnel, verify synthetic or approved public requests fail through both SOCKS5 remote DNS and HTTP, capture DNS on the direct interface, and restore service. Explain that one failed curl alone does not prove all TCP/UDP/IPv6 paths safe.
- [ ] Run acceptance matrix: cold start without connectivity; repeated failures beyond `QUARANTINE_AFTER`; process restart while offline; restoration of connectivity; alternative candidate succeeds; candidate flaps; both ranking modes; fast start; tunnel disappearance; endpoint DNS failure; explicit LAN destination; default metadata denial; allowed client receives replies. Verify file preservation and actual traffic path separately.
- [ ] Perform a whole-diff review, rerun all applicable tests, and record exact commands/results plus privileged or architecture checks not executed. Do not claim leak freedom from mock results.
- [ ] Commit: `ci: verify failover safety and document hardened network policy`.

## Completion and rollback

- Each task requires failing regression evidence first and passing evidence after implementation; each commit must leave its own declared behavior usable.
- Task order is 1 → 2 → 3 → 4 → 5 → 6 → 7. Base-image inspection may be pulled forward if resolver/timeout compatibility needs it; do not choose a digest without inspecting it.
- A release requires the real namespace and isolated Docker checks, not only mocks. No live deployment is included.
- Deployment is a separately authorized operation: privately back up compose/env/config and quarantine state, record the previous image digest, explain the explicit LAN migration, then recreate during an agreed interruption window.
- Rollback restores the previous image/config snapshot, not arbitrary Git state. Never automatically restore quarantined configs or erase persistent strike state.
- Follow-up projects remain separate: authentication and proxy replacement; least-privilege/read-only container; observability; automatic failback; image publication and broader architecture qualification.
