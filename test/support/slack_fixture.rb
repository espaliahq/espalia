# frozen_string_literal: true

# A connected tenant with a framework and three people for the inbound Slack
# tests: a signed-up giver, an assessed recipient, and a Person known from HRIS
# who has never signed in. Shared so every endpoint test starts from one shape.
module SlackFixture
  SECRET = "test-signing-secret"
  TEAM_ID = "T0GROWTH"

  def build_slack_fixture
    @tenant = create(:tenant)
    @tenant.connect_slack!(bot_token: "xoxb-test", team_id: TEAM_ID, team_name: "me&u")
    @giver_user = create(:user, password: "password123", email: "jordan@example.com")
    @recipient_user = create(:user, password: "password123", email: "alex@example.com")

    ActsAsTenant.with_tenant(@tenant) do
      @giver = create(:person, tenant: @tenant, email: @giver_user.email, name: "Jordan Lee")
      @recipient = create(:person, tenant: @tenant, email: @recipient_user.email, name: "Alex Chen")
      @newcomer = create(:person, tenant: @tenant, email: "newcomer@example.com", name: "Nia Newcomer")
      @giver_tu = create(:tenant_user, tenant: @tenant, user: @giver_user, person: @giver, role: :member, slack_user_id: "U_JORDAN")
      create(:tenant_user, tenant: @tenant, user: @recipient_user, person: @recipient, role: :member)

      @framework_id = SecureRandom.uuid_v7
      @framework = create(:framework_state, framework_id: @framework_id, name: "Eng")
      rf = create(:framework_role_family, framework_id: @framework_id, name: "Eng")
      role = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      level = create(:framework_level, role_id: role.role_id, ordinal: 2, title: "Mid", code: "E2")
      cat = create(:framework_capability_category, framework_id: @framework_id, name: "Thinking", ordinal: 1)
      @cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
      create(:framework_capability_role_binding, capability_id: @cap.capability_id, role_id: role.role_id, weight: 1.0)
      create(:framework_behavioural_expectation, capability_id: @cap.capability_id, level_ordinal: 2, description: "x")
      PersonDevelopment::CommandHandler.new.assign_to_framework(@recipient.id, @framework_id, role.role_id, level.level_id)
      @assignment = PersonFrameworkAssignment.find_by(person_id: @recipient.id, framework_id: @framework_id)
    end
  end

  # A Slack client double: records every call, answers the lookups the
  # identity resolution and the DMs need.
  class FakeClient
    attr_reader :calls

    def initialize(emails: {})
      @emails = emails
      @calls = []
    end

    def user_email(slack_user_id) = @emails[slack_user_id]
    def lookup_user_id_by_email(email) = @emails.key(email)
    def open_view(trigger_id:, view:) = (@calls << [ :open_view, trigger_id, view ]; { "ok" => true })
    def post_dm(slack_user_id:, text:, blocks: nil) = (@calls << [ :post_dm, slack_user_id, text, blocks ]; { "ok" => true })
    def permalink(channel:, message_ts:) = "https://slack.example/archives/#{channel}/p#{message_ts.delete('.')}"
  end

  def with_fake_slack(emails: { "U_JORDAN" => "jordan@example.com", "U_NIA" => "newcomer@example.com", "U_GHOST" => "ghost@example.com" })
    fake = FakeClient.new(emails: emails)
    Slack::Client.stub(:new, fake) { yield fake }
  end

  def signed_slack_headers(body, timestamp: Time.now.to_i.to_s)
    { "X-Slack-Signature" => Slack::RequestVerifier.sign(timestamp: timestamp, body: body, secret: SECRET),
      "X-Slack-Request-Timestamp" => timestamp }
  end
end
