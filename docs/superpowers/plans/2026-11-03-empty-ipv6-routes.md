# Empty IPv6 Routes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Permit startup when IPv6 route lists are empty and Docker provides no IPv6 gateway, without relaxing checks for requested routes.

**Architecture:** Tokenize comma/space-delimited route lists in `scripts/proxy-routes.sh` before deciding whether a gateway is required. Add a regression case to the existing mocked-`ip` shell test, then validate with the project suite and an isolated live TR tunnel.

**Tech Stack:** POSIX shell, existing shell test harness, Docker, SSH, AmneziaWG 2.0.

**Spec:** `docs/superpowers/specs/2026-11-03-empty-ipv6-routes-design.md`

## Global Constraints
- Preserve gateway, CIDR, route installation and rollback behavior for actual routes.
- Use synthetic credentials for repository tests.
- The real tunnel check must use a fresh temporary TR peer and leave the server's original config and peer list intact.
- Do not touch unrelated services on `.173`.

## Review Focus
- Empty values combined with separators must not count as requested routes; cover empty IPv6 lists with no gateway in Task 1.
- Whitespace-only values must also resolve to no route; cover with the same regression test.
- A non-empty IPv6 route with no gateway must still fail before calling `ip`; retain existing missing-gateway test and assert no route call.
- Comma-separated valid routes must still install exactly; retain existing exact-route assertions.
- A route installation failure must still roll back earlier routes; retain existing rollback assertion.

---

### Task 1: Fix route-list parsing with regression coverage

**Files:**
- Modify: `tests/proxy-routes-test.sh`
- Modify: `scripts/proxy-routes.sh`

**Interfaces:**
- Consumes: `install_family(family, networks, gateway)` arguments formed by the current environment-variable concatenation.
- Produces: Empty token lists return success without gateway checks or `ip` calls; non-empty token lists retain current behavior.

- [x] **Step 1: Add the failing regression test**

In `tests/proxy-routes-test.sh`, clear `ROUTE_CALLS` and invoke the script with all four route variables empty, an IPv4 gateway present and the IPv6 gateway empty, matching the observed Docker bridge condition. Assert success and that `ROUTE_CALLS` remains empty. Include whitespace/comma separators in one empty variable to cover tokenization, for example `LAN_NETWORK6=' ,  '`. Keep existing missing-gateway, exact-route, invalid-CIDR and rollback cases unchanged.

- [x] **Step 2: Verify the test fails for the intended reason**

Run: `sh tests/proxy-routes-test.sh`
Expected: FAIL because the current implementation treats the joined empty IPv6 values as requested routes and reports a missing IPv6 gateway.

- [x] **Step 3: Tokenize before checking the gateway**

In `scripts/proxy-routes.sh`, convert commas to spaces, split into the function's positional parameters with pathname expansion disabled, return successfully when the resulting argument count is zero, and iterate the resulting route tokens. Keep the gateway guard after the empty-list check and preserve route validation/install/rollback logic.

- [x] **Step 4: Verify regression and route behavior**

Run: `sh tests/proxy-routes-test.sh`
Expected: PASS, including empty-list success, missing-gateway rejection, exact route calls and rollback.

### Task 2: Run repository verification and isolated live tunnel test

**Files:**
- No additional repository files; use temporary artifacts only on `.173` and TR.

**Interfaces:**
- Consumes: Updated scripts and tests from Task 1.
- Produces: Recorded pass/fail evidence and clean temporary-resource state.

- [x] **Step 1: Run the full project verification**

Run the repository's documented shell tests, build/image smoke, Compose validation, DNS policy checks, ShellCheck and Hadolint. Expected: all previously passing checks remain green.

- [x] **Step 2: Create and stage a fresh temporary TR peer**

Confirm current TR service/peer state, back up active config and manager backup privately, create one uniquely named temporary peer with `awg-client`, and stage its config mode `0600` only in a new isolated `/tmp/security-failover-real` directory on `.173`. Do not print or log key material.

- [x] **Step 3: Build and run the isolated container**

Build the changed checkout in a temporary context on `.173`. Run only a uniquely named test container, on Docker bridge with no unrelated service dependencies, using the temporary config. Verify container startup, active-config marker, positive AWG handshake, transfer counters, tunnel health, and both HTTP and SOCKS proxy egress matching the TR server IP.

- [x] **Step 4: Remove test resources and reconcile TR**

Remove only the test container/image, staged config, build context/archive, and temporary peer. Verify `awg-client list` has exactly the pre-test clients, active `awg0.conf` is byte-identical to its pre-test copy, manager backup is restored, and `awg-quick@awg0` remains active. Do not remove recovery copies until these checks pass.
