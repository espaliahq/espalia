# frozen_string_literal: true

require "test_helper"
require_relative "../../support/slack_fixture"

class Slack::IdentityTest < ActiveSupport::TestCase
  include SlackFixture

  setup { build_slack_fixture }

  should "resolve a member by the cached Slack id without asking Slack" do
    fake = SlackFixture::FakeClient.new(emails: {})
    identity = Slack::Identity.resolve(team_id: TEAM_ID, slack_user_id: "U_JORDAN", client: fake)
    assert identity.member?
    assert_equal @giver.id, identity.person.id
    assert_equal @giver_user.id, identity.authorization_context.user.id
  end

  should "resolve a member by email and cache the Slack id" do
    ActsAsTenant.with_tenant(@tenant) { @giver_tu.update_column(:slack_user_id, nil) }
    fake = SlackFixture::FakeClient.new(emails: { "U_NEW" => "JORDAN@example.com" })
    identity = Slack::Identity.resolve(team_id: TEAM_ID, slack_user_id: "U_NEW", client: fake)
    assert identity.member?
    assert_equal "U_NEW", @giver_tu.reload.slack_user_id
  end

  should "never match a membership on a blank Slack id" do
    create(:tenant_user, tenant: @tenant, user: create(:user), role: :member, slack_user_id: nil) # a member with no cached id
    with_fake_slack do
      identity = Slack::Identity.resolve(team_id: SlackFixture::TEAM_ID, slack_user_id: nil)
      assert_not identity.connected?
      assert_not identity.member?
    end
  end

  should "tell a Person without an account apart from a stranger" do
    fake = SlackFixture::FakeClient.new(emails: { "U_NIA" => "newcomer@example.com", "U_GHOST" => "ghost@example.com" })
    nia = Slack::Identity.resolve(team_id: TEAM_ID, slack_user_id: "U_NIA", client: fake)
    assert nia.person_only?
    assert_not nia.member?
    assert_equal "newcomer@example.com", nia.email

    ghost = Slack::Identity.resolve(team_id: TEAM_ID, slack_user_id: "U_GHOST", client: fake)
    assert ghost.connected?
    assert_not ghost.member?
    assert_not ghost.person_only?
  end

  should "be unconnected for an unknown workspace" do
    identity = Slack::Identity.resolve(team_id: "T_NOPE", slack_user_id: "U_JORDAN", client: SlackFixture::FakeClient.new)
    assert_not identity.connected?
  end
end
