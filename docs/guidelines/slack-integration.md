# Slack Integration

> Read this when: touching anything under `app/integrations/slack/`,
> `app/controllers/slack/`, the Slack delivery method, the app manifest, or
> a feature that reaches people in Slack. The architecture background is in
> [docs/architecture/integrations.md](../architecture/integrations.md).

## Two directions, one app

**Outbound** is notifications: `SlackDeliveryMethod` DMs a Noticed
notification to its recipient over the tenant's workspace, after the in-app
copy has had its minute to be read ([assessments.md → Comment
notifications](assessments.md)). **Inbound** is the feedback modal: the
`/growthos feedback` slash command and the "Give feedback on this message"
shortcut open it, and its submission records evidence as the Slack user.

The app is installed per tenant (`Tenant#connect_slack!` keeps the bot token
and the workspace's `slack_team_id`), with app-level credentials from
`Slack.oauth_config`. The manifest in `app/integrations/slack/manifest.yml`
is the source of truth for scopes, the command, the shortcut and the request
URLs; `Slack::BOT_SCOPES` must match it, since the install grants what that
list says, not what the manifest says.

## Inbound requests

Three session-less endpoints, all authenticated by the request **signature**
(`SlackSignedRequest`, over `request.raw_post` — never re-serialised params)
and none under Devise or CSRF:

| Endpoint | Controller | Answers |
|---|---|---|
| `POST /slack/events` | `Slack::EventsController` | the `url_verification` challenge; real events are acked and dropped until a reply handler exists |
| `POST /slack/commands` | `Slack::CommandsController` | `/growthos feedback [text]` — opens the modal; anything else, usage |
| `POST /slack/interactions` | `Slack::InteractionsController` | the modal's recipient typeahead (`block_suggestion`), its submission (`view_submission`), the message shortcut (`message_action`) |

**Who is asking** is `Slack::Identity.resolve(team_id:, slack_user_id:)`:
the tenant by `slack_team_id`, then the membership by the id cached on
`TenantUser.slack_user_id` or by the email Slack holds (`users.info`), caching
the id on the way through — the same column the outbound delivery fills, so
both directions agree. Three outcomes, each with its own answer:

- a **member** acts now, through an `AuthorizationContext` built the way the
  MCP server builds one, with `AuditMetadata.with(acting_via: :slack)`;
- a **Person with no account** (HRIS-imported, never signed in) is told to
  submit anyway: the submission becomes a `FeedbackDraft` and they are DM'd
  its link (below);
- anyone else is told no account matches their Slack email.

**Three seconds.** Slack discards a `trigger_id` after three seconds and
expects the HTTP answer in the same window, so the command and shortcut
handlers resolve the identity and call `views.open` and nothing else; the
work happens on submission. A slash command's error is the JSON response
itself (`response_type: ephemeral`); a shortcut's goes by DM.

## The feedback modal

`Slack::FeedbackModal` builds the view and reads the submission, so the block
ids written are the ones read. Recipient is an `external_select` fed by
`Assessments::FeedbackRecipients` (the same directory as the web and MCP);
content, type, and an optional capability with its valence. **A capability
alone means the recipient's current level** — a phone-sized modal has no room
for a level ladder, and leaving it blank records the item unplaced for the
recipient or their manager to place, exactly as on the web
([assessments.md → Proactive feedback](assessments.md)). The capability list
is the first framework's, capped at Slack's 100 options; a cell the
recipient's role has no expectation at comes back as a form error, not a
failed write. The message shortcut prefills the text and keeps the message's
permalink as the external reference (`system: "slack"`).

`Slack::Feedback` holds what the two controllers share: opening the modal,
`Operations::Assessments::RecordEvidence` as the giver, the draft path, and
the DMs that close each loop (a confirmation to the giver; the link to a
first-timer).

## First sign-in: the draft and its link

A Person without an account cannot write. `Slack::Feedback.draft` keeps the
submission as a `FeedbackDraft` — bound to the author's email, 14 days,
consumed once — and DMs `/evidence/drafts/<token>`. Devise stores that path
on the way to sign-in, so after signing in (Google sign-in provisions the
account for an HRIS Person) `Evidence::DraftsController` checks the email,
sets the tenant and sends them to the hub with `?draft=`, where the
`evidence-hub` controller opens the modal straight on the recipient's form,
filled from the draft; saving consumes it. The capability is not kept — the
web form offers the full picker. Pinned end to end by
`test/integration/slack_draft_deep_link_test.rb` and a system test.

## Testing

`test/support/slack_fixture.rb` gives a connected tenant, three people (a
member, a recipient, a never-signed-in Person) and `FakeClient`, a recording
double for `Slack::Client` with the lookups the identity resolution and the
DMs need; `with_fake_slack` stubs the client for a block and
`signed_slack_headers` signs a raw body with the test secret. Sign bodies
exactly as Slack does — a form-encoded payload is signed as sent, not as
parsed.

## Gotchas

- **Phlex and Block Kit both escape**: build blocks as hashes and let the
  client serialise; never interpolate user text into JSON strings.
- **`should_escape: false` on the command** keeps `@mentions` as plain text
  in `text`; the modal does not parse them — the recipient is chosen in the
  modal, deliberately, so the write always has an assignment.
- **A reconnect clears cached Slack ids** (`Tenant#connect_slack!`), so a
  workspace change re-resolves everyone by email on next contact.
