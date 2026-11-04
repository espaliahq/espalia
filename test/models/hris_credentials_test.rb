# frozen_string_literal: true

require "test_helper"

class HrisCredentialsTest < ActiveSupport::TestCase
  setup { @tenant = create(:tenant) }

  context "the wrapper" do
    should "read the known keys and nothing else" do
      credentials = HrisCredentials.new(
        "service_user_id" => "svc-1", "api_token" => "tok-secret", "webhook_secret" => "hook-secret", "other" => "x"
      )

      assert_equal "svc-1", credentials.service_user_id
      assert_equal "tok-secret", credentials.api_token
      assert_equal "hook-secret", credentials.webhook_secret
      assert credentials.complete?
    end

    should "treat nil, blanks and a non-hash as not set" do
      [ nil, {}, { "api_token" => "" }, "tok-secret" ].each do |raw|
        assert_not HrisCredentials.new(raw).complete?, raw.inspect
      end
      assert_not HrisCredentials.new("service_user_id" => "svc-1").complete?
    end

    should "say which values are set, for display" do
      stored = HrisCredentials.new("api_token" => "tok-secret").stored

      assert_equal({ "service_user_id" => false, "api_token" => true, "webhook_secret" => false }, stored)
    end

    should "never print a value" do
      credentials = HrisCredentials.new("service_user_id" => "svc-1", "api_token" => "tok-secret", "webhook_secret" => "hook-secret")

      assert_equal "#<HrisCredentials service_user_id=true api_token=true webhook_secret=true>", credentials.inspect
      assert_equal credentials.inspect, credentials.to_s
      assert_no_match(/tok-secret|hook-secret/, "#{credentials}")
    end
  end

  context "Tenant#update_hris!" do
    should "store the credentials encrypted" do
      @tenant.update_hris!(service_user_id: "svc-1", api_token: "tok-secret", webhook_secret: "hook-secret")

      stored = ActiveRecord::Base.connection.select_value("SELECT hris_credentials FROM tenants WHERE id = '#{@tenant.id}'")
      assert_not_includes stored, "tok-secret"
      secrets = @tenant.reload.hris_secrets
      assert_equal "svc-1", secrets.service_user_id
      assert_equal "tok-secret", secrets.api_token
      assert_equal "hook-secret", secrets.webhook_secret
    end

    should "keep a credential when its field is left blank" do
      @tenant.update_hris!(service_user_id: "svc-1", api_token: "tok-secret")
      @tenant.update_hris!(service_user_id: "", api_token: nil, webhook_secret: "hook-secret")

      secrets = @tenant.reload.hris_secrets
      assert_equal "svc-1", secrets.service_user_id
      assert_equal "tok-secret", secrets.api_token
      assert_equal "hook-secret", secrets.webhook_secret
    end

    should "merge settings and keep the unlisted ones" do
      @tenant.update_hris!(settings: { provider: "hibob", level_field_id: "column_1" })
      @tenant.update_hris!(settings: { sync_enabled: true })

      config = @tenant.reload.hris_config
      assert_equal "hibob", config.provider
      assert_equal "column_1", config.level_field_id
      assert config.sync_enabled?
    end

    should "keep sync state a job wrote since this tenant was loaded" do
      stale = Tenant.find(@tenant.id)
      @tenant.with_lock do
        @tenant.hris_config.last_synced_at = Time.zone.parse("2026-11-01 10:00")
        @tenant.save!
      end

      stale.update_hris!(settings: { provider: "hibob" })

      config = stale.reload.hris_config
      assert_equal "hibob", config.provider
      assert_equal Time.zone.parse("2026-11-01 10:00"), config.last_synced_at
    end

    should "refuse an unknown provider" do
      assert_raises(ActiveRecord::RecordInvalid) { @tenant.update_hris!(settings: { provider: "workday" }) }
      assert_nil @tenant.reload.hris_config.provider
    end
  end
end
