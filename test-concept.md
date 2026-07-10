# Test Concept – Ratatoskr

> **Scope:** overarching, cross-component test strategy for the Ratatoskr system.
> **Status:** Draft

## 1. Overview

Ratatoskr lets a user play **Audiobookshelf** audiobooks on **Sonos** speakers
from a phone, keeping listening progress in sync. The full system-under-test for
end-to-end testing consists of **four parts**:

| Part | What | Ownership |
|---|---|---|
| App | Android app (Kotlin/Compose) – "thin remote", talks **only** to the server over HTTPS `/v1/`; no audio, no domain logic | [ratatoskr-app](https://github.com/Xexanos/ratatoskr-app) |
| Ratatoskr server | The bridge (Node.js). Controls Sonos (UPnP/SOAP), talks to ABS (REST). Audio never flows through it | [ratatoskr-server](https://github.com/Xexanos/ratatoskr-server) |
| Audiobookshelf (ABS) | **External.** Audiobook server; source of truth for progress and authentication | third-party |
| Fake Sonos | **Custom test double (this repo).** Stands in for physical speakers over local UPnP/SOAP. The official Sonos simulator does *not* fit — it targets the cloud Control API, not the local protocol the server uses (see §4). **Not equal to real hardware** (see §2, manual verification) | this repo |

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
| Component | one subsystem of a single component against simulated neighbors (e.g. the app's networking layer, the server's position-mapping module) | app / server repo | repo-local |
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
| Manual real-hardware verification | real Sonos/SYMFONISK devices — the fake cannot reproduce all UPnP behavior (DIDL-Lite metadata, `REL_TIME` seeking, unreliable reported track duration) | **here (central, process)** |

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

| Scope | Tool | Notes |
|---|---|---|
| E2E – stack orchestration | docker-compose | Ratatoskr server + Audiobookshelf image + the fake Sonos, one command |
| E2E – Sonos | **custom stateful UPnP/SOAP fake** | The official Sonos simulator targets the cloud Control API, not the local UPnP/SOAP the server uses. A hand-built fake works (feasibility validated — see below). **Owned by the server repo** (one module, two run-modes: in-process for its component tests, a GHCR image here) and consumed here pinned by digest — so server tests and E2E never drift. Wired via the server's `SONOS_SEED_HOST` (no SSDP multicast needed). Real audio playback stays manual (§2) |
| E2E – driving the app | **Maestro** (black-box, UiAutomator) | Requires `Modifier.semantics { testTagsAsResourceId = true }` + `testTag`s in the app (§9). Low lock-in: switching to Appium later rewrites only the thin flow layer, selectors carry over |
| E2E – ABS assertions | small TypeScript harness | HTTP client against the ABS API to assert progress write-back (E2E-06) |
| Repo-local (Unit/Component/Integration) | *owned per repo* | see each repo's `docs/testing.md` |

> **Feasibility (validated by a throwaway spike):** the exact library the server uses
> (`@svrooij/sonos`) drives such a fake over local UPnP/SOAP with no hardware — both the
> direct control flow and the full `SonosDevice.LoadDeviceData()` + `Coordinator` path.
> Findings that shape the real fake: `LoadDeviceData()` needs only
> `DeviceProperties.GetZoneAttributes` + `RenderingControl` volume/mute (no
> `device_description.xml` / `ZoneGroupTopology`); discovery avoids SSDP via
> `SONOS_SEED_HOST`; the server polls, so no UPnP event subscription is needed.

---

## 5. E2E Scenarios

Cross-component use cases to be covered (most important happy paths + critical
failure cases — not full coverage). Failure/resilience cases live **inside** E2E,
not as a separate level.

The **Coverage** column notes how each scenario is covered: **Automated** (fully
driven in E2E), **+ ABS-state assertion** (also asserts server-written progress via
the ABS API), or **control/state automated · audio manual** (the fake validates the
control flow and reported transport state; the actual audio playback falls to manual
real-hardware verification — see §2).

| ID | Scenario | Prio | Coverage | Status |
|---|---|---|---|---|
| E2E-01 | Connect to server by URL + TLS trust-on-first-use (confirm fingerprint) | P1 | Automated | Planned |
| E2E-02 | Sign in with ABS credentials (server-proxied); session survives app restart | P1 | Automated | Planned |
| E2E-03 | Browse + search the library | P1 | Automated | Planned |
| E2E-04 | Start a book on a speaker → resumes from stored position | P1 | control/state automated · audio manual | Planned |
| E2E-05 | Now-playing: play / pause / seek / stop | P1 | control/state automated · audio manual | Planned |
| E2E-06 | Progress synced back to ABS (source of truth) | P1 | Automated + ABS-state assertion | Planned |
| E2E-07 | Sign out | P2 | Automated | Planned |
| E2E-08 | 401 → silent token refresh; active session continues | P2 | Automated | Planned |
| E2E-09 | Speaker disappears mid-session | P2 | Automated | Planned |
| E2E-10 | ABS unreachable → sensible error surfaced in the app | P2 | Automated | Planned |

**Setup requirements implied by these scenarios:**

- The harness must be able to **read ABS state** (ABS API), not just run ABS as a
  black box — needed to assert progress in E2E-06.
- ABS needs **fixture data**: a known user + at least one audiobook with a known
  starting position (E2E-04, E2E-06).
- **Single active session** is a system invariant (one book on one speaker at a
  time) — scenarios must not assume concurrent sessions.

---

## 6. CI/CD Integration

**Principle:** cadence ∝ cost & flakiness. Cheap, fast, deterministic tests run on
every PR and block merges; expensive/slow E2E (emulator + docker-compose + Maestro,
and dependent on built artifacts) runs off the PR critical path. Because E2E runs on
**every merge to main**, `main` stays continuously E2E-validated — so a release is
just a git tag on a green `main` commit, with no separate release-time E2E gate.

There is deliberately **no scheduled (nightly) run**. To make that safe, **all
external inputs are pinned by digest** — the ABS image, base images, the emulator
system image, and dependencies via lockfiles. Environment drift can then only enter
through a deliberate pin-bump PR, which is itself E2E-gated, so drift is always
attributed to the change that introduced it rather than surfacing later on an
unrelated PR.

| Trigger | What runs | Blocking |
|---|---|---|
| **PR** (any repo) | that repo's **full** suite. server: lint, typecheck, unit, component, integration, oasdiff breaking-change guard, debug build. app: lint, unit, instrumented (component + UI-integration + accessibility) on emulator, debug `.apk`. e2e: full E2E vs. both components' last releases (for PRs that touch the harness/tests) | ✅ yes |
| **Merge to `main`** (server / app) | rebuild + publish the `main` artifact, then `repository_dispatch` → the e2e repo runs E2E per the version matrix below (blocking: `main` × the other component's last release; informational: `main` × `main`) | ✅ keeps `main` green |
| **Merge to `main`** (e2e) | full E2E vs. both components' last releases (blocking) + `main` × `main` (informational) — see matrix | ✅ |
| **Release** = git tag `v*` on a green `main` commit | build + sign + publish the release artifacts (multi-arch image, signed `.apk`); create the GitHub Release. No separate E2E gate — `main` was already validated | — |
| **Manual** (`workflow_dispatch`) | targeted E2E for debugging; the compatibility matrix (ABS versions, Android range, Sonos models), run on demand and before a major release | — |

**E2E trigger mechanics:** the e2e repo owns no artifacts, so its E2E job is triggered
by (a) `repository_dispatch` from the server/app repos when they publish a new `main`
artifact, (b) `workflow_dispatch` (manual), and (c) its own PRs that change the harness. Releases are driven by **git tags** (`on: push: tags: ['v*']` or
`on: release: types: [published]`), not by watching a version number. Cross-repo dispatch
needs a token (PAT or GitHub App) with access to the e2e repo.

### Artifacts & version matrix

**How artifacts move — one model for both.** Everything E2E pulls lives in **GHCR**
and is pinned by digest (consistent with the no-scheduled-run decision above):

- **server image** — pushed natively (`docker push`).
- **app `.apk`** — pushed as an OCI artifact via **ORAS**
  (`oras push ghcr.io/xexanos/ratatoskr-app:<tag> app.apk`), pulled the same way.
- **fake Sonos image** — built and published by the **server repo** (which owns the
  fake); pulled here pinned by digest like the others.

We deliberately do **not** use GitHub Actions artifacts for this: they cannot be
digest-pinned, expire (default 90 days), and are awkward to fetch across repos.

Two channels, published from CI (**PR builds are never published**):

- **rolling** on each merge to `main` — `:main` plus an immutable `:main-<sha>`
  (a GHCR cleanup policy prunes old shas).
- **permanent** on release — `:v1.2.0` + `:latest`.

The release `.apk` may additionally ship as a GitHub Release asset / to F-Droid for
end-user distribution; that path is separate from E2E consumption.

**Which versions E2E runs** (on a merge to `main` of repo X; the other repo = Y):

| Combination | Purpose | Blocking |
|---|---|---|
| X@`main` × Y@**last release** | compatibility with the version in the field (server `SPEC.md §6` requires bidirectional compat); failure is cleanly attributable to X's change | ✅ yes |
| X@`main` × Y@`main` | early integration signal for the two development tips; may go red because of Y's unreleased WIP, so it must not block X | ⚠️ non-blocking |

For a PR/merge in the **e2e repo** (a harness change with no artifact of its own),
the blocking run is **both components @ last release** (a stable baseline, so a
failure points at the harness); `main` × `main` is the optional informational run.

> Still gated on deployable artifacts (server Docker image, app `.apk`) existing —
> see [Roadmap](#8-roadmap). Until then this describes the target cadence.

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

1. **Done:** this test concept — levels/types §2, tooling §4, scenario draft §5,
   CI cadence §6 — is written and agreed; the fake-Sonos approach is validated.
2. **Now:** cross-repo prep (§9) — `docs/testing.md` in the app/server repos and
   the app `testTag` change for black-box driving.
3. **Blocked on artifacts:** a Docker image for the server and an `.apk` for the
   app (neither exists yet).
4. **Then:** build the actual E2E suite here against those artifacts (docker-compose
   stack: server + ABS + fake Sonos; app via emulator/device).
5. **Then:** wire up CI (§6) and update the E2E scenario statuses (§5) as tests land.

---

## 9. Open Points

- [x] Decide E2E tooling (stack orchestration + app driving) — §4
- [x] Draft E2E scenarios — §5 *(priorities may still be adjusted)*
- [x] Define CI cadence — §6
- [x] Add `testTag`s + `testTagsAsResourceId` to the app for black-box driving — merged: [app#15](https://github.com/Xexanos/ratatoskr-app/pull/15)
- [ ] Pin the E2E emulator/app locale (e.g. `en-US`): most elements are driven by text / contentDescription rather than test tags, so text selectors need a fixed UI language to stay stable (the app ships en-US + de-DE — see app `docs/testing.md`)
- [ ] Fake Sonos: enforce DIDL-Lite metadata (reject bare URL like real UPnP 714) so E2E catches server regressions
- [x] Create `docs/testing.md` in the app and server repos (link back here) — merged: [server#16](https://github.com/Xexanos/ratatoskr-server/pull/16), [app#11](https://github.com/Xexanos/ratatoskr-app/pull/11)
- [ ] Define staging/fixture data for ABS in E2E
- [ ] Pin all external E2E inputs by digest (ABS image, base images, emulator system image, lockfiles) — prerequisite for having no scheduled run (§6)
- [ ] Verify a single CI runner can host the Android emulator (needs KVM) **and** the docker-compose stack together — feasibility risk for the E2E job
- [ ] Provision E2E secrets/fixtures beyond ABS content: a known server TLS cert + fingerprint (E2E-01 trust-on-first-use) and ABS user credentials + the low-privilege streamer account (E2E-02)
