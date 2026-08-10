# Contributing

This is a proof of concept, worked on when there is time. That shapes what you can
expect.

## Issues

**Open them — they are welcome and they are read.** Bug reports, questions and ideas are
all useful, and a report that something does not work is worth more than a patch that
guesses at the cause.

**No promise that anything gets implemented, or when.** Priorities move with what the
project is proving next. An issue that stays open is not being ignored; it is queued
behind whatever is currently load-bearing. If something matters to you and has gone
quiet, say so on the issue.

A good report says what you ran, what happened, and what you expected. For anything
involving Swarm, include the reference or ENS name and the gateway or node you used —
the same content behaves differently across gateways, and that difference is usually the
answer.

## Pull requests

Welcome, and easier to accept when small. Open an issue first for anything structural,
so you do not spend an evening on an approach that does not fit.

Two things that will be asked of any change:

- **Verify it against the live network**, not only in theory. This project has produced
  several bugs where every call reported success and nothing was published. `tests/` has
  the end-to-end checks; they skip cleanly when the environment is not configured.
- **Do not change the on-Swarm format** (`swarm-git/1`) without saying so explicitly.
  Published repositories depend on it, and a silent change orphans them. The format is
  specified in [`docs/spec-swarm-git-format-v1.md`](docs/spec-swarm-git-format-v1.md).

Commit messages: say what changed and why it was wrong before. No AI or tool attribution.

## Running it

```sh
npm install && npm link          # puts git-remote-bzz on PATH
./tests/e2e-push-clone.sh        # needs a Bee node, a postage batch and a signing key
```

Reading needs none of that — see [`docs/addressing.md`](docs/addressing.md).

## What is out of scope

CI, server-side merge, and anything requiring compute: Swarm is storage. Issues and
patches are intended to live in the repository as Git objects rather than in a bespoke
tracker — see the open issue on adopting git-bug or Radicle collaborative objects.
