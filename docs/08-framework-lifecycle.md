# Framework Lifecycle

How career frameworks evolve over time — from creation through versioning, collaborative editing, and publication. This is the conceptual guide; for event schemas and read model tables, see [docs/architecture/framework-aggregate.md](architecture/framework-aggregate.md).

---

## The Big Picture

A framework is a living document. People fix typos, refine expectations, add new capabilities, retire outdated ones. The lifecycle is designed so that **most changes flow instantly** while **structural changes are batched into versions** to protect in-flight assessments.

```
Create framework
  |
  v
Bootstrap v1 draft (automatic)
  |  populate roles, levels, capabilities, expectations...
  v
Publish v1 ---> assessments can begin
  |
  |--- editorial changes flow live (typos, rewording, illustrations)
  |--- suggestions accumulate and get reviewed
  |
  v
Open v2 draft (explicit or auto-opened by suggestion approval)
  |  add/retire capabilities, change level structure...
  |  define migration mappings for retired capabilities
  v
Publish v2 ---> projection rebuilds, assessment migrations fire
  |
  ...and so on
```

---

## Two Kinds of Change

Every framework change falls into one of two categories. The distinction matters because it determines whether people see the change immediately or only after a version is published.

### Shape-preserving (editorial) changes

Changes that **don't alter the rating grid** — the set of capabilities and level ordinals that assessments depend on. These apply instantly to the published view, with or without a draft in progress.

Examples:
- Renaming the framework itself (tenant admin or owner — the header's inline pencil)
- Renaming a role family, role, or capability category
- Rewording a capability description
- Updating a behavioural expectation's text (the description changes, but the "slot" in the grid stays)
- Adding, editing, or removing role illustrations
- Tweaking a capability-role binding weight

No version bump. No draft needed. Assessments continue unaffected.

### Shape-changing (structural) changes

Changes that **alter the rating grid** — adding or removing the slots that people are rated against. These are deferred behind a draft and only become visible when the version is published.

Examples:
- Adding a new capability (new row of ratings in the matrix)
- Archiving a capability (removing a row — what happens to existing ratings?)
- Adding a new level (new column of ratings)
- Changing level ordinals (reordering columns)
- Creating or removing a capability-role binding (changes which roles see which capabilities)
- Setting a new behavioural expectation (adds a new "cell" in the grid)

These require a draft because in-flight assessments froze a `framework_version` at define time. Applying a structural change to the published view mid-assessment would corrupt the rating grid people are working against.

---

## The Draft Phase

A draft is a staging area for structural changes. While a draft is open:
- Shape-changing events accumulate in the event stream but are **invisible in the published projection**
- Editorial changes continue flowing live, unaffected by the draft
- The framework's published view stays frozen at the current version
- Editors working on the draft see pending changes via the draft projection

### How drafts open

There are three ways a draft starts:

1. **Bootstrap draft** — When a framework is first created, a v1 draft opens automatically. The creator populates it with initial structure and publishes v1.

2. **Explicit `start_draft`** — An owner or editor opens a draft for the next version (e.g. v2). Used when planning deliberate structural changes.

3. **Auto-opened by suggestion approval** — When a reviewer approves a shape-changing suggestion and no draft is in progress, the aggregate implicitly opens one. The draft's `started_by` is the approver; subsequent shape-changing approvals join the same draft. This enables bottom-up structural improvement without requiring an admin to pre-open a draft.

### How drafts close

Only one way: **`publish_version`**, callable by `owner` or `editor` roles. Publication triggers a full projection rebuild — all child read models are destroyed and the event stream is replayed from the beginning with the draft flag cleared, making the structural changes visible.

Publishing is gated:
- If any capability was archived during the draft and it existed before the draft started, you must define a **migration mapping** for it first. This prevents silently orphaning people's ratings.
- If migration mappings are missing, `publish_version` raises with a list of the capabilities that need them.

---

## Collaborative Editing via Suggestions

Framework changes flow through a suggestion system inspired by Google Docs' "suggestion mode". Anyone with the right collaborator role can propose changes; reviewers approve or reject them.

### Three suggestion kinds

| Kind | What it does | Example |
|------|-------------|---------|
| **Edit** | Changes a field value on an existing entity | "Reword this expectation from X to Y" |
| **Create** | Proposes adding a new entity | "Add a 'Resilience' capability under Thinking" |
| **Delete** | Proposes removing an entity | "Archive the 'Legacy Systems' capability" |

### Three review tiers

Not all suggestions carry the same risk. The tier determines who can approve:

| Tier | What's being changed | Who can approve |
|------|---------------------|-----------------|
| **Tier 1** (light) | Role illustrations | Any edit-role holder (owner, editor, or any lead) |
| **Tier 2** (moderate) | Capability/category descriptions | Owner, editor, capability category lead, capability lead |
| **Tier 3** (high) | Behavioural expectations | Owner, editor, capability category lead, capability lead |

### What happens on approval

The effect depends on whether the underlying change is shape-preserving or shape-changing:

**Shape-preserving suggestion approved** (e.g. rewording an illustration):
- The change applies immediately to the published view
- No draft is needed or opened
- Assessments see the updated text right away

**Shape-changing suggestion approved** (e.g. creating a new capability):
- If a draft is already open: the structural event joins it
- If no draft is open: one is auto-opened, then the event lands in it
- The change is invisible in the published view until owner/editor publishes

### Auto-approval

When an author with approval authority makes a change in "editing mode" (the default), the system creates a suggestion and immediately auto-approves it. This keeps the audit trail (every change is a suggestion) while not slowing down authorised editors.

Authors without approval authority, or those explicitly choosing "suggesting mode", create suggestions that wait for review.

---

## Migration Mappings

When a capability is archived during a draft, people may have ratings against it. Migration mappings tell the system what to do with those ratings when the new version is published.

| Mapping type | Meaning | Rating behaviour |
|-------------|---------|-----------------|
| **same** | Capability unchanged (just re-affirming) | Ratings carry forward |
| **evolved** | Capability broadened or narrowed, or absorbed into an existing one | Ratings carry forward; reassessment likely flagged. Where the person already rated the survivor at the same level, the survivor's rating stays and the absorbed rating is kept under the retired capability, flagged `capability_merged` |
| **split** | Capability split into multiple new ones | Ratings blanked; reassessment required |
| **archived** | Capability retired with no replacement | Ratings surface for relink or dismiss |
| **new** | Brand new capability (no predecessor) | Starts blank |

Every archived capability (that existed before the draft started) must have a mapping before publishing. This is enforced — `publish_version` will reject otherwise, listing which capabilities need attention.

---

## Common Workflows

### "I want to fix a typo in an expectation"

1. Navigate to the expectation in the framework explorer
2. Suggest an edit with the corrected text
3. If you have approval authority, it auto-applies immediately
4. If not, it waits for a reviewer to approve — then applies immediately

No draft, no version bump. Shape-preserving.

### "I want to add a new capability"

1. Suggest creating the capability under its category
2. If approved and a draft is open, it joins the draft
3. If approved and no draft is open, a draft auto-opens
4. The new capability is invisible in the published view until publish
5. Owner/editor publishes when ready — projection rebuilds, capability appears

Shape-changing. Requires a draft (opened explicitly or auto-opened).

### "I want to retire an old capability"

1. Suggest deleting (archiving) the capability
2. On approval, a draft opens if none exists
3. Before publishing, define a migration mapping:
   - `archived` if there's no replacement
   - `evolved` if it's been absorbed into another capability
   - `split` if it's been broken into multiple new ones
4. Publish — existing ratings migrate per the mapping rules

Shape-changing. Migration mapping mandatory before publish.

### "I want to reorganise levels"

1. Open an explicit draft via `start_draft` (this is a planned structural change)
2. Add, reorder, or modify levels as needed
3. Define migration mappings for any affected capabilities
4. Publish when the new structure is ready

Shape-changing. Typically done explicitly rather than via suggestions.

---

## Who Can Do What

| Action | Who |
|--------|-----|
| **View published framework** | Anyone with `viewer` role or above |
| **View draft changes** | `collaborator` role or above |
| **Suggest edits** | `collaborator` role or above |
| **Approve suggestions** | Depends on tier (see above) |
| **Make direct editorial changes** | Edit-role holders (owner, editor, leads) |
| **Open an explicit draft** | `owner`, `editor` |
| **Publish a version** | `owner`, `editor` |
| **Manage collaborators** | `owner` only (or tenant admin) |

Collaborator roles are scoped — a `capability_lead` on "Strategic Thinking" can approve changes to that capability but not others. Permissions are the **union** of all roles a person holds (additive, never subtractive).

---

## How the Two Projections Work

The same event stream powers two different views of the framework:

**Published projection** — What assessors and managers see. Skips shape-changing events while a draft is in progress. On `FrameworkVersionPublished`, it wipes all child read models and replays the entire stream with the draft flag cleared, making all deferred events visible.

**Draft/editor projection** — What framework editors see. Replays all events including pending structural changes. Shows inline suggested edits. (Not yet fully implemented in UI — see todos/05.)

Both projections handle editorial events identically — they always apply live.

---

## Further Reading

| Resource | When to read it |
|----------|----------------|
| [Architecture: Framework Aggregate](architecture/framework-aggregate.md) | Event schemas, read model tables, aggregate state |
| [Architecture: ADRs](architecture/adrs.md) | Why decisions were made (ADR-5, ADR-7, ADR-16, ADR-17) |
| [Versioning flow diagram](07-versioning-flow.mermaid) | Visual overview of draft/publish event flow |
| [Framework structure diagram](05-framework-structure.mermaid) | Two-layer expectation model |
| [Glossary](02-glossary.md) | Precise definitions of all domain terms |
| [Guideline: Framework Explorer](guidelines/framework-explorer.md) | UX patterns for the matrix view |
