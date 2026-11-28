# frozen_string_literal: true

require "test_helper"

class Mcp::AccessTokenTest < ActiveSupport::TestCase
  setup do
    @user = create(:user)
    @tenant = create(:tenant)
    @application = Mcp::Application.create!(name: "Client", redirect_uri: "https://client.example/cb", scopes: "read", confidential: false)
    @previous = issue(refresh_token: "previous-refresh-token")
  end

  def issue(**attributes)
    Mcp::AccessToken.create!(application: @application, resource_owner_id: @user.id, tenant_id: @tenant.id,
                             scopes: "read", expires_in: 3600, **attributes)
  end

  should "refuse a refresh from a token revoked with a stamp ahead of this clock" do
    @previous.update_columns(revoked_at: 1.second.from_now)

    assert_raises(Doorkeeper::Errors::InvalidGrantReuse) { issue(previous_refresh_token: "previous-refresh-token") }
  end

  should "refuse a refresh from a revoked token" do
    @previous.update_columns(revoked_at: 1.second.ago)

    assert_raises(Doorkeeper::Errors::InvalidGrantReuse) { issue(previous_refresh_token: "previous-refresh-token") }
  end

  should "issue a refresh from a live token" do
    assert issue(previous_refresh_token: "previous-refresh-token").persisted?
  end
end
