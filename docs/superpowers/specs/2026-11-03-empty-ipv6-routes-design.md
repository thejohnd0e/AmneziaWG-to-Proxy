# Design: Ignore empty IPv6 route lists

## Intent
Allow the proxy container to start when IPv6 is unavailable and no IPv6 bypass or client-return routes were requested. The bug occurs because two empty route variables are joined with a space, which passes the current non-empty check and incorrectly requires an IPv6 gateway.

## Goals and boundaries
- Treat a route list containing no CIDRs as empty before checking its gateway.
- Preserve gateway validation, CIDR validation, route installation, and rollback for actual routes.
- Add a regression test for empty IPv6 lists with no IPv6 gateway.
- After repository tests pass, repeat the isolated real-TR AWG test with a fresh temporary peer; remove it and all test artifacts, and verify the TR config and peer list are restored.
- Do not touch unrelated services on `.173`.

## Approaches
- **Tokenize the route list before gateway validation (selected):** commas/spaces are parsed into route tokens; an empty token set returns successfully. Minimal scope and fixes the cause while retaining validation for real CIDRs.
- Normalize the entrypoint environment variables before calling the script: leaves `proxy-routes.sh` incorrect for other callers and duplicates responsibility, so not selected.

## Validation and calls left to the implementer
Use the existing shell regression harness with synthetic routes and a mocked `ip` command. Verify the new case fails before the fix and passes after it, then run the full project test/lint/build checks. The real tunnel test is isolated and uses a newly approved temporary TR peer; verify handshake, health, and HTTP/SOCKS egress before cleanup. No other behavior or server configuration changes are in scope.
