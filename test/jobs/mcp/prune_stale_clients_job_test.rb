# frozen_string_literal: true

require "test_helper"

class Mcp::PruneStaleClientsJobTest < ActiveSupport::TestCase
  setup do
    @user   = create(:user)
    @tenant = create(:tenant)
  end

  # Factory shorthand — we want to control dynamically_registered_at
  # and the latest token's created_at independently of Time.current.
  def dcr_app(name:, registered_at:, last_token_at: nil)
    app = Mcp::Application.create!(
      name: name, redirect_uri: "http://localhost:7777/cb",
      scopes: "read", confidential: false,
      dynamically_registered_at: registered_at
    )
    if last_token_at
      Mcp::AccessToken.create!(
        application: app, resource_owner_id: @user.id, tenant_id: @tenant.id,
        scopes: "read", expires_in: 3600, created_at: last_token_at
      )
    end
    app
  end

  def manual_app(name:)
    Mcp::Application.create!(
      name: name, redirect_uri: "http://localhost:7777/cb",
      scopes: "read", confidential: false
      # dynamically_registered_at intentionally nil — admin-registered
    )
  end

  context "scope: dcr_stale" do
    should "select DCR apps whose latest token (or registration time) is past the cutoff" do
      stale_no_token  = dcr_app(name: "stale-no-token",  registered_at: 60.days.ago)
      stale_old_token = dcr_app(name: "stale-old-token", registered_at: 60.days.ago, last_token_at: 45.days.ago)
      fresh_token     = dcr_app(name: "recently-used",   registered_at: 60.days.ago, last_token_at: 1.day.ago)
      recently_registered = dcr_app(name: "newly-registered", registered_at: 2.days.ago)
      _manual         = manual_app(name: "admin-app")

      ids = Mcp::Application.dcr_stale.pluck(:id)

      assert_includes ids, stale_no_token.id
      assert_includes ids, stale_old_token.id
      refute_includes ids, fresh_token.id
      refute_includes ids, recently_registered.id
      # Admin apps must never be selected — dynamically_registered_at is nil.
      assert_equal 0, Mcp::Application.dcr_stale.where(dynamically_registered_at: nil).count
    end
  end

  context "#perform" do
    should "delete stale DCR apps and their dependent tokens/grants" do
      stale = dcr_app(name: "stale", registered_at: 60.days.ago, last_token_at: 45.days.ago)
      Mcp::AccessGrant.create!(
        application: stale, resource_owner_id: @user.id, tenant_id: @tenant.id,
        token: "g1", expires_in: 60, redirect_uri: "http://localhost:7777/cb",
        scopes: "read", created_at: 45.days.ago
      )

      result = nil
      assert_difference -> { Mcp::Application.count }, -1 do
        assert_difference -> { Mcp::AccessToken.count }, -1 do
          assert_difference -> { Mcp::AccessGrant.count }, -1 do
            result = Mcp::PruneStaleClientsJob.new.perform
          end
        end
      end
      assert_equal 1, result[:deleted]
      refute Mcp::Application.exists?(stale.id)
    end

    should "leave manual apps untouched even if no tokens exist" do
      admin = manual_app(name: "admin")
      Mcp::PruneStaleClientsJob.new.perform
      assert Mcp::Application.exists?(admin.id)
    end

    should "return {deleted: 0} when nothing is stale" do
      dcr_app(name: "fresh", registered_at: 1.day.ago)
      result = Mcp::PruneStaleClientsJob.new.perform
      assert_equal({ deleted: 0 }, result)
    end

    should "accept a Duration override for the cutoff (ops/testing)" do
      app = dcr_app(name: "10-day-old", registered_at: 10.days.ago)
      # Default 30-day window: untouched.
      Mcp::PruneStaleClientsJob.new.perform
      assert Mcp::Application.exists?(app.id)
      # 7-day window: removed.
      Mcp::PruneStaleClientsJob.new.perform(cutoff: 7.days)
      refute Mcp::Application.exists?(app.id)
    end
  end
end
