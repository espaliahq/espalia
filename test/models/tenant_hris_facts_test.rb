# frozen_string_literal: true

require "test_helper"

class TenantHrisFactsTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
  end

  def providers
    ActsAsTenant.with_tenant(@tenant) do
      OrgGraph::StructureAggregate::FACTS.index_with { OrgFactProvider.provider_for(it) }.compact
    end
  end

  context "connecting an HRIS" do
    should "leave a fact an admin chose for Espalia before connecting" do
      ActsAsTenant.with_tenant(@tenant) do
        OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM).set_fact_provider("title", "espalia", effective_on: Date.current)
      end
      @tenant.update_hris!(settings: { provider: "hibob", sync_enabled: true }, service_user_id: "user", api_token: "token")

      assert_equal "espalia", providers["title"]
      assert_equal "hibob", providers["level"]
    end

    should "hand it the facts it supplies by default, and nothing else" do
      @tenant.update_hris!(settings: { provider: "hibob", sync_enabled: true }, service_user_id: "user", api_token: "token")

      assert_equal OrgGraph::StructureAggregate::HRIS_FACTS.index_with("hibob"), providers.select { _2 == "hibob" }
      assert_equal "espalia", providers["cost_centre"]
    end

    should "claim nothing until the HRIS is configured" do
      @tenant.update_hris!(settings: { provider: "hibob", sync_enabled: false }, service_user_id: "user", api_token: "token")

      assert(providers.values.all?("espalia"))
    end

    should "keep the HRIS's facts on disconnect, as handing them back is a handover" do
      @tenant.update_hris!(settings: { provider: "hibob", sync_enabled: true }, service_user_id: "user", api_token: "token")
      @tenant.disconnect_hris!

      assert_equal "hibob", providers["title"]
    end

    should "leave a fact an admin handed back to Espalia when the settings are saved again" do
      @tenant.update_hris!(settings: { provider: "hibob", sync_enabled: true }, service_user_id: "user", api_token: "token")
      ActsAsTenant.with_tenant(@tenant) do
        OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM).set_fact_provider("title", "espalia", effective_on: Date.current)
      end
      @tenant.update_hris!(settings: { sync_enabled: true })

      assert_equal "espalia", providers["title"]
    end
  end

  should "keep the saved settings when claiming fails" do
    failing = Object.new
    def failing.claim_facts(*, **) = raise("stream unavailable")

    OrgGraph::StructureCommandHandler.stub(:new, failing) do
      @tenant.update_hris!(settings: { provider: "hibob", sync_enabled: true }, service_user_id: "user", api_token: "token")
    end

    assert_equal "hibob", @tenant.reload.hris_config.provider
  end
end
