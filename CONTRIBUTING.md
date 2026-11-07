# Contributing to Espalia

Thanks for helping. This file covers the mechanics; the engineering
conventions live in [AGENTS.md](AGENTS.md) and the per-layer guides under
[docs/guidelines/](docs/guidelines/) — read the guide for each layer you touch
before writing code. They are written for AI coding agents and humans alike,
and they are the review standard your PR is held to.

## Where development happens

Espalia is developed entirely at
[espaliahq/espalia](https://github.com/espaliahq/espalia). Downstream
deployments — including the me&u instance the project grew out of — are
forks that track that repo and carry only their own deployment
configuration; no product development happens in them. If you run a fork,
send product changes upstream first — even when only your deployment needs
them — and pull them back with the rest of upstream. That keeps every fix
and feature shared instead of stranded in one deployment.

## Getting set up

```bash
bin/setup        # dependencies + database (PostgreSQL required)
bin/dev          # app on http://localhost:6600
bin/rails test   # the suite
```

The repo ships a devcontainer that provides Ruby, PostgreSQL and Chrome;
`bin/setup` works outside it too. Seeding creates the Null Island Systems
example tenant with a published framework, people and assessment activity, and
a dev admin (`admin@example.com` / `password123`, development only).

## Making a change

- **Start from an issue.** Open one first if it doesn't exist, so the problem
  and approach are agreed before the diff arrives.
- **One issue, one PR, stacked commits.** Commit each discrete change as it's
  completed, with concise [conventional commit](https://www.conventionalcommits.org)
  messages that say what value the commit creates.
- **Every behaviour change gets a test.** Minitest; system tests (Capybara)
  for anything user-facing, at both viewports when responsive. See
  [docs/guidelines/testing.md](docs/guidelines/testing.md).
- **Front-end changes get a visual pass** in a real browser, not just a green
  suite. Include screenshots in the PR for new or changed UI.
- **New user-facing surfaces consider MCP exposure.** Build through
  `Operations::*` so the web UI and the MCP server share one implementation,
  or say in the PR why not ([docs/guidelines/mcp-server.md](docs/guidelines/mcp-server.md)).
- **Update any documentation your change falsifies**, in the same PR.

## Before opening the PR

```bash
bin/rails development:precommit
```

It runs linting (RuboCop, erb_lint), security checks (Brakeman, bundler-audit,
importmap audit) and the full test suite, system tests included. It must be
fully green — fix what it reports even when it looks unrelated to your change.

PR descriptions say why, what, how it was tested, and `Closes #<issue>`.

## Security issues

Never as a public issue or PR — see [SECURITY.md](SECURITY.md).

## Licensing

Espalia is MIT-licensed. By contributing you agree your contributions are
licensed under the same terms ([LICENSE](LICENSE)); there is no CLA.
