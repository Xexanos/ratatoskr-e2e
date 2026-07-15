# Ratatoskr E2E

![Ratatoskr logo](https://github.com/Xexanos/ratatoskr-app/raw/main/docs/logo/ratatoskr-logo.svg)

Central repository for cross-component testing and the overarching test
documentation of the Ratatoskr system.

Ratatoskr lets a user play Audiobookshelf audiobooks on Sonos speakers from a
phone. The full end-to-end system-under-test consists of **four parts**: the
Android **app**, the Ratatoskr **server** (the bridge), **Audiobookshelf (ABS)**
as an external dependency, and a custom **fake Sonos** (a UPnP/SOAP double built
in the server repo) standing in for physical speakers.

## Current status

The overarching [test concept](./test-concept.md) plus the **P1 E2E harness**:
a docker-compose stack (server + ABS + fake Sonos), Maestro flows that drive the
installed app APK on an emulator, and a CI workflow. It exercises the P1 scenario
spine (E2E-01…06). The P2 failure cases are a fast-follow.

See [Roadmap in the test concept](./test-concept.md#8-roadmap) for details.

## What's here?

- **[test-concept.md](./test-concept.md)** – overarching test strategy: test
  levels & types, the central/repo-local split, and E2E scenarios.
- **[compose.e2e.yaml](./compose.e2e.yaml)** – the stack: ABS + fake Sonos + server.
- **[flows/](./flows/)** – Maestro flows driving the app black-box (P1 spine).
- **[scripts/](./scripts/)** – `run-e2e.sh` orchestrator, ABS seeding + progress
  assertion, artifact fetch, fixture generator.
- **[.github/workflows/e2e.yml](./.github/workflows/e2e.yml)** – the CI suite.

## Related repos

| Component | Repo |
|---|---|
| Server (bridge) | [ratatoskr-server](https://github.com/Xexanos/ratatoskr-server) |
| App (Android) | [ratatoskr-app](https://github.com/Xexanos/ratatoskr-app) |
| Audiobookshelf (ABS) | external – [audiobookshelf.org](https://www.audiobookshelf.org/) |
| Fake Sonos | custom UPnP/SOAP double, image built + published by the server repo |

Repo-local test documentation (unit/integration test conventions per component)
lives in `docs/testing.md` in the BE and FE repo respectively, and links back
to the [test concept](./test-concept.md) here.

## Setup

Prerequisites: Docker + docker-compose, `gh` (authenticated), `jq`, `python3` (to
generate the fixture audiobook WAV), and — for driving the app — a running **Android
emulator** (API 36) with `adb`, plus the [Maestro](https://maestro.mobile.dev) CLI.

## Running tests locally

```sh
# 1. Resolve + pull the pinned artifacts (server + fake-sonos images, app APK).
#    Override the defaults with SERVER_IMAGE / FAKE_SONOS_IMAGE / APP_RELEASE_TAG.
GH_TOKEN="$(gh auth token)" bash scripts/fetch-artifacts.sh

# 2. Bring up the stack (ABS + fake Sonos + server) and seed ABS.
bash scripts/run-e2e.sh up

# 3. With an emulator running and Maestro installed: install the APK, run the
#    flows, and assert the ABS write-back (E2E-06).
bash scripts/run-e2e.sh drive

# 4. Tear it down.
bash scripts/run-e2e.sh down
```

`run-e2e.sh all` does 2–4 in one go. The server validates the ABS streamer key at
startup, so `up` deliberately seeds ABS **before** starting the server.

## Tests in CI

[`e2e.yml`](./.github/workflows/e2e.yml) runs on `ubuntu-latest` (emulator via
`reactivecircus/android-emulator-runner`, mirroring the app repo's instrumented CI).
It is triggered by a `repository_dispatch` (`server-image`) from the server repo
after it publishes a new `main` image, by `workflow_dispatch` (manual, with
optional pins), and on pull requests here. On a green `server-image` run it
dispatches `e2e-passed` back so the server promotes the exact tested image.

## License

See [LICENSE](./LICENSE).