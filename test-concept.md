# Test Concept – Ratatoskr

> **Scope:** overarching, cross-component test strategy for the Ratatoskr system.
> **Status:** Draft
> **Last updated:** 2026-07-07

## 1. Overview

Ratatoskr lets a user play **Audiobookshelf** audiobooks on **Sonos** speakers
from a phone, keeping listening progress in sync. The full system-under-test for
end-to-end testing consists of **four parts**:

| Part | What | Ownership |
|---|---|---|
| App | Android app (Kotlin/Compose) – "thin remote", talks **only** to the server over HTTPS `/v1/`; no audio, no domain logic | [ratatoskr-app](https://github.com/Xexanos/ratatoskr-app) |
| Ratatoskr server | The bridge (Node.js). Controls Sonos (UPnP/SOAP), talks to ABS (REST). Audio never flows through it | [ratatoskr-server](https://github.com/Xexanos/ratatoskr-server) |
| Audiobookshelf (ABS) | **External.** Audiobook server; source of truth for progress and authentication | third-party |
| Sonos simulator | **External test double.** Official Sonos control simulator standing in for physical speakers in E2E. **Not equal to real hardware** (see §2, manual verification) | third-party |

This document defines what is documented **centrally** (here) and what is
documented **locally per repo**. Repo-local test documentation lives in
`ratatoskr-server/docs/testing.md` and `ratatoskr-app/docs/testing.md`
respectively and links back to this document — it is not duplicated.

> **Current status:** this repo currently only contains this test concept.
> The actual E2E test suite will be added once deployable artifacts exist for
> both owned components (a Docker image for the server, an `.apk` for the app) —
> see [Section 8](#8-roadmap).

---

## 2. Test Levels & Test Types

We model tests along **two independent axes**.

### Axis 1 — Levels (scope of the system-under-test)

| Level | Scope | Executed where | Documented where |
|---|---|---|---|
| Unit | single function/class, isolated | app / server repo | repo-local |
| Component | one subsystem of a single component against simulated neighbors (e.g. networking layer, DB access) | app / server repo | repo-local |
| Integration | a complete single application/component against mocks | app / server repo | repo-local |
| E2E | full 4-part stack (App + server + ABS + Sonos simulator), no mocks | **this repo** | **here (central)** |

> Rule of thumb: everything that tests **one** component (in isolation or against
> simulated neighbors) is repo-local. Only tests that exercise the **real
> interaction of all parts together** are central — that is E2E, and it lives here.

### Axis 2 — Types (quality attribute, orthogonal to level)

These run *at* one or more levels; they are not additional pyramid layers.

| Type | What | Where |
|---|---|---|
| Accessibility | a11y checks per screen, light + dark | repo-local (app) |
| Security | TLS trust-on-first-use, token rotation, encrypted token storage, low-privilege streamer account, log redaction | repo-local + periodic review |
| Compatibility | matrix: ABS version (≥ 2.26), Android range (SDK 26–36), Sonos/SYMFONISK models | repo-local / matrix |
| Manual real-hardware verification | real Sonos/SYMFONISK devices — the simulator cannot reproduce all UPnP behavior (DIDL-Lite metadata, `REL_TIME` seeking, unreliable reported track duration) | **here (central, process)** |

---

## 3. No dedicated Contract level (rationale)

There is intentionally **no contract-test level**. The app↔server wire contract
is a single OpenAPI spec (`ratatoskr-server/contract/openapi.yaml`) from which
**both sides generate code** (Kotlin client in the app, TypeScript types in the
server). The type-level contract is therefore correct *by construction* — a
"do the schemas match" test would be redundant.

The two residual risks are covered elsewhere:

- **Runtime conformance** (does the running server actually emit spec-conformant
  responses — enum values, error shapes, token-rotation handover?) → verified
  **server-internally** (integration tests against the raw contract).
- **Version drift** (does the contract version the app pins match what the server
  serves?) → surfaces naturally in **E2E**, where the real app talks to the real
  server.

---

## 4. Tools & Frameworks

> Decided independently of what the repos currently use. Central concern here is
> the **E2E tooling**; repo-local tool choices are owned by the respective repo's
> `docs/testing.md`.

| Scope | Tool |
|---|---|
| E2E – stack orchestration (server + ABS + Sonos sim) | *TBD (to be decided together)* |
| E2E – driving the app | *TBD (to be decided together)* |
| Repo-local (Unit/Component/Integration) | *owned per repo* |

---

## 5. E2E Scenarios

Cross-component use cases to be covered (most important happy paths + critical
failure cases — not full coverage). Failure/resilience cases live **inside** E2E,
not as a separate level.

| ID | Scenario | Priority | Status |
|---|---|---|---|
| — | *TBD (to be derived from product behavior together)* | | |

---

## 6. CI/CD Integration

> To be decided independently — which tests run when (push/PR vs. nightly vs.
> after a release candidate).

| Repo | Trigger | What runs |
|---|---|---|
| ratatoskr-server | *TBD* | *TBD* |
| ratatoskr-app | *TBD* | *TBD* |
| ratatoskr-e2e | *TBD* | E2E (blocked until artifacts exist — see §8) |

> Not yet applicable until deployable artifacts (server Docker image, app `.apk`)
> are available — see [Roadmap](#8-roadmap).

---

## 7. Maintenance & Review Policy

- Changes to test levels/types, E2E scenarios, or this concept: PR against this repo.
- **Review policy (solo project):** PRs are authored by @Xexanos and reviewed with
  Claude Code review; the same applies to any future external PRs. No per-level
  responsibility matrix is maintained while the project is single-maintainer.
- Repo-local test docs (`docs/testing.md` in the app/server repo) link back here
  and are **not** duplicated or included as a submodule — a plain markdown link is
  sufficient:

  ```markdown
  ## Test Concept
  The overarching test strategy is documented in the central repo:
  → [ratatoskr-e2e/test-concept.md](https://github.com/Xexanos/ratatoskr-e2e/blob/main/test-concept.md)
  ```

---

## 8. Roadmap

1. **Now:** write and agree on this test concept.
2. **Next (open design points):** decide E2E tooling (§4), derive & prioritize
   E2E scenarios (§5), define CI cadence (§6).
3. **Once available:** Docker image for the server and `.apk` for the app as
   deployable artifacts.
4. **Then:** set up the actual E2E test suite in this repo, targeting those
   artifacts (stack via docker-compose for server + ABS + Sonos simulator; app
   via emulator/device).
5. **Then:** wire up CI (§6) and fill in the E2E scenario table (§5).

---

## 9. Open Points

- [ ] Decide E2E tooling (stack orchestration + app driving) — §4
- [ ] Derive and prioritize E2E scenarios — §5
- [ ] Define CI cadence per repo — §6
- [ ] Create `docs/testing.md` in the app and server repos (link back here)
- [ ] Define staging/fixture data for ABS in E2E
