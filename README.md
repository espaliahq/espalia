# Espalia

Espalia is an open-source, multi-tenant platform for operationalising career
growth frameworks — and, over time, for capability-based team planning built
on the same foundations. Organisations define their career paths (role
families, roles, levels, capabilities, behavioural expectations) and use the
platform to run self-assessments, manager alignment conversations, evidence
collection and growth planning.

The name comes from *espalier*: a plant trained up a frame, tier by tier.

The platform embodies a simple philosophy: performance is multi-dimensional,
and culture is the sum of consistently demonstrated behaviours. A career path
is three things at once — a cultural blueprint (what behaviours to reward), a
performance map (what good looks like at each level) and a development roadmap
(how to grow within or across roles).

## What it does

- **Framework authoring** — roles, levels, capabilities and behavioural
  expectations, edited collaboratively with inline suggested edits (Google
  Docs style), versioned with draft/publish semantics, and migrated safely
  when the framework's shape changes. The full history is event-sourced.
- **Assessments** — self-ratings and manager ratings against the framework,
  alignment conversations that formalise agreement, and assessment cycles that
  run a cohort through the process with progress tracking.
- **Evidence** — collected continuously, linked to capabilities, requested
  from peers, and carried across framework versions.
- **Growth planning** — focus areas, growth plans and check-ins on each
  person's development stream.
- **Calibration** — sessions that put ratings side by side and capture notes,
  flags and revisit requests.
- **Reporting** — capability attainment, evidence coverage, cycle cohort
  views and promotion-readiness signals.
- **MCP server** — the same operations that power the web UI are exposed over
  the [Model Context Protocol](https://modelcontextprotocol.io), with OAuth,
  so AI assistants can read and write frameworks, assessments and evidence on
  a person's behalf. Importing an existing framework via MCP is the documented
  onboarding path: [docs/import-your-framework.md](docs/import-your-framework.md).
- **Integrations** — HRIS sync (HiBob today; adapter pattern for others),
  Slack notifications and feedback capture, a signed feedback exchange with
  peer systems, and optional AI assistance. All credentials are tenant-level,
  entered through the UI and encrypted at rest.

## Technology

Rails 8 on PostgreSQL, with [RailsEventStore](https://railseventstore.org)
for the event-sourced domains, Hotwire (Turbo + Stimulus with import maps),
Phlex views and components, TailwindCSS v4, Solid Queue/Cache/Cable, Devise
and Pundit. No Node.js dependency.

[AGENTS.md](AGENTS.md) holds the architecture overview and the engineering
conventions; [docs/](docs/) holds the design documents and per-layer guides.

## Getting started

Requires Ruby (see [.ruby-version](.ruby-version)) and PostgreSQL — or use
the included devcontainer, which provides both plus a browser for system
tests.

```bash
bin/setup   # dependencies, database, seeds
bin/dev     # http://localhost:6600
```

Seeding creates **Null Island Systems**, a fictional example tenant with a
published engineering + product framework, an org chart, an assessment cycle
in flight, evidence and suggested edits — enough to explore every feature. In
development you can sign in as the seeded admin (`admin@example.com`) or as
seeded people like `marisol@nullisland.example` (manager) and
`theo@nullisland.example` (engineer) — the development password is
`password123` throughout.

To bring in your organisation's real framework, follow
[docs/import-your-framework.md](docs/import-your-framework.md).

```bash
bin/rails test                   # the suite
bin/rails development:precommit  # lint + security + full suite; the PR gate
```

## Deployment

Espalia runs standalone: the Rails app, PostgreSQL and Solid Queue — no other
services required. A [render.yaml](render.yaml) blueprint is included for
[Render](https://render.com); any host that runs Rails and Postgres works.
Bootstrap the first admin with `SEED_ADMIN_EMAIL` / `SEED_ADMIN_PASSWORD` (or
`bin/rails admin:create`), and configure integrations per tenant through the
UI once signed in.

## Theming

An organisation's admin picks a theme under **Tenant admin → Theme**:

- **Default**, the standard look.
- **Bento**, a complete preset with its own colours and font.
- **Custom**, Default with the organisation's own brand colour, navbar colour
  and font. Each colour has a light and a dark value, and the platform picks
  the text that goes on it, so it always stays readable.

Each person chooses Auto, Light or Dark under **Appearance** in the user menu.

To build a screen, start with
[the component catalogue](app/components/README.md); to build or change
anything with colour, read
[the theming guide](docs/guidelines/theming.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security reports go to
**security@espalia.app**, not the issue tracker — see
[SECURITY.md](SECURITY.md).

## History and license

Espalia began life as **GrowthOS**, the internal growth platform at
[me&u](https://www.meandu.com); you'll still see that name in places until the
product name becomes configurable. MIT-licensed — see [LICENSE](LICENSE).
The Espalia name and mark are trademarked separately and not granted by the
license.
