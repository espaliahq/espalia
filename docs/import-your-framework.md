# Import your framework through MCP

Your career framework probably already exists — in Notion, a spreadsheet, a
PDF, a wiki. The fastest way into Espalia is not retyping it and not writing
YAML: connect an AI agent to the Espalia MCP server, hand it the source
document, and let it build the framework through the same tools the web app
uses. The result is a reviewable draft; nothing is visible to your
organisation until you publish it.

(The YAML path exists too — `frameworks:seed` loads a file shaped like
[db/seeds/null_island_framework.yml](../db/seeds/null_island_framework.yml) —
but it is a bootstrap for empty databases, not an editor: it refuses to run
once a framework exists.)

## Before you start

1. **Create the framework in the web app** (Frameworks → New). There is
   deliberately no MCP tool for this; creating it in the browser also opens
   the v1 draft the import will fill.
2. **Connect an MCP client** as a user who can edit the framework (owner or
   editor collaborator, or a tenant admin). The server advertises the
   `frameworks_*` tools once connected.
3. **Give the agent the source material and the mapping rules**: what counts
   as a role family, a role, a level, a capability, a per-level expectation,
   and a role-specific example (illustration). The two-layer model matters —
   the *expectation* is the canonical text people are rated against, one per
   capability × level; *illustrations* are optional clarifying examples per
   role.

## The build order

Structure first, then content — each step's tools fail clearly if the parent
is missing:

1. `frameworks_add_role_family` → `frameworks_add_role` →
   `frameworks_add_level` (one level per rateable step of each role; the
   lowest ordinal is the entry level).
2. `frameworks_add_category` → `frameworks_add_capability`.
3. `frameworks_add_capability_role_binding` for every capability × role that
   is rated, with `weight` where capabilities are not equally important and
   `individual_tolerance: 0` for a capability that is non-negotiable
   (rendered as **Required**).
4. `frameworks_set_behavioural_expectation` for every capability × level
   ordinal the bound roles can be rated at.
5. Illustrations go through the suggestion flow:
   `frameworks_suggest_create` (target `role_illustration`, with the parent
   expectation and the role), then `frameworks_approve_suggestion` — an
   author with edit rights can approve their own creations.
6. Review the draft in the web app (the explorer shows the draft view), then
   **publish from the browser**: `frameworks_publish_version` is an in-app
   approval, so the final click is always a person's.

## What to expect

- **It takes minutes, not seconds.** A real framework is several hundred tool
  calls. That is fine: everything lands in the v1 draft, invisible until
  publish.
- **Interruptions are recoverable, but resume by reading, not re-adding.**
  The draft keeps everything built so far. Levels reject duplicates, and
  re-setting an existing expectation cell rejects too (though while the same
  author has a pending create for that cell, the call amends it and returns
  `amended: true`). Roles, categories, capabilities and bindings do **not**
  dedupe — each re-add mints a new entity. Have the agent re-read the built
  structure (`frameworks_get`, `frameworks_draft_changes`) and add only what
  is missing.
- **Nothing publishes by accident.** Structure-changing work accumulates in
  the draft; `publish_version` requires in-app confirmation.
- **Verify as you go.** `frameworks_get` and `frameworks_draft_changes` let
  the agent (and you) check the built structure against the source document
  — ask the agent for a diff summary before you publish.

## Known gaps

- A category-level `deficit_threshold` has no MCP tool or web control yet;
  per-capability `individual_tolerance` on bindings covers the common case
  (marking a capability Required).
- There is no bulk-import operation. If an import ever genuinely hurts at
  hundreds of calls, that is the follow-up to ask for — the draft-batch
  machinery the seed loader uses (`Frameworks::Repository#batch`) is the
  obvious backend for one.

## After the import

People, assignments and cycles are app-side work, not import work: connect
your HRIS (Integrations → HRIS) or add people manually, assign them to roles,
and define a cycle. The demo tenant (`bin/rails db:seed` in development)
shows what a fully-populated workspace looks like.
