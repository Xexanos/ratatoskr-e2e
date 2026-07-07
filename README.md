# Ratatoskr E2E

![Ratatoskr logo](https://github.com/Xexanos/ratatoskr-app/raw/main/docs/logo/ratatoskr-logo.svg)

Central repository for cross-component testing and the overarching test
documentation of the Ratatoskr system.

Ratatoskr lets a user play Audiobookshelf audiobooks on Sonos speakers from a
phone. The full end-to-end system-under-test consists of **four parts**: the
Android **app**, the Ratatoskr **server** (the bridge), **Audiobookshelf (ABS)**
as an external dependency, and the official **Sonos simulator** as a test double
for physical speakers.

## Current status

This repo currently contains **only the test concept**. The actual E2E test
suite will be added once deployable artifacts exist for both owned components:

- a **Docker image** for the server
- an **`.apk`** for the app

See [Roadmap in the test concept](./test-concept.md#8-roadmap) for details.

## What's here?

- **[test-concept.md](./test-concept.md)** – overarching test strategy: test
  levels & types, the central/repo-local split, and E2E scenarios.
- **`e2e/`** – *(to be added)* the actual end-to-end test suite exercising the
  full stack together, once artifacts are available.

## Related repos

| Component | Repo |
|---|---|
| Server (bridge) | [ratatoskr-server](https://github.com/Xexanos/ratatoskr-server) |
| App (Android) | [ratatoskr-app](https://github.com/Xexanos/ratatoskr-app) |
| Audiobookshelf (ABS) | external – [audiobookshelf.org](https://www.audiobookshelf.org/) |
| Sonos simulator | external test double for E2E |

Repo-local test documentation (unit/integration test conventions per component)
lives in `docs/testing.md` in the BE and FE repo respectively, and links back
to the [test concept](./test-concept.md) here.

## Setup

*(to be added once the E2E test suite exists)*

## Running tests locally

*(to be added once the E2E test suite exists)*

## Tests in CI

*(to be added once the E2E test suite exists)*

## License

See [LICENSE](./LICENSE).