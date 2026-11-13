# frozen_string_literal: true

require "test_helper"

class Operations::Tenants::ScheduledForgettingTest < ActiveSupport::TestCase
  PROVENANCE = { provider: "espalia", effective_on: "2020-01-01" }.freeze

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @leaver = create(:person, tenant: @tenant)
      handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      handler.sync_person(@leaver.id, **PROVENANCE, employment_status: "employed")
      handler.sync_person(@leaver.id, **PROVENANCE, employment_status: "left", left_on: "2010-01-01")
    end
  end

  def as(role)
    tenant_user = ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, role:) }
    AuthorizationContext.new(user: tenant_user.user, tenant_user:, person: nil)
  end

  def call(operation, context: as(:admin), **params)
    ActsAsTenant.with_tenant(@tenant) { operation.call(context:, params:) }
  end

  def config = @tenant.reload.org_graph_config

  context "the dry run" do
    should "count who is due, by id, and erase nobody" do
      result = call(Operations::Tenants::ForgettingDryRun)

      assert_equal({ tenant_id: @tenant.id, retention_years: 7, count: 1, person_ids: [ @leaver.id ] }, result)
      assert_not @leaver.reload.forgotten?
    end

    should "refuse without the forgetting key" do
      OrgGraph::Forgetting.stub(:key, nil) do
        assert_raises(Operations::Base::ParameterError) { call(Operations::Tenants::ForgettingDryRun) }
      end
    end

    should "refuse anyone but a tenant admin" do
      assert_raises(Pundit::NotAuthorizedError) { call(Operations::Tenants::ForgettingDryRun, context: as(:member)) }
    end
  end

  context "turning the schedule on" do
    should "need the count the dry run gives, and record who turned it on" do
      admin = as(:admin)
      assert_raises(Operations::Base::ParameterError) do
        call(Operations::Tenants::EnableScheduledForgetting, context: admin, confirm_count: 0)
      end
      assert_not config.scheduled_forgetting

      result = call(Operations::Tenants::EnableScheduledForgetting, context: admin, confirm_count: 1)

      assert_equal({ tenant_id: @tenant.id, scheduled_forgetting: true, confirmed_count: 1 }, result)
      assert config.scheduled_forgetting
      assert_equal admin.tenant_user.id, config.scheduled_forgetting_enabled_by_id
      assert_not_nil config.scheduled_forgetting_enabled_at
      assert_not @leaver.reload.forgotten?
    end

    should "refuse without the forgetting key" do
      OrgGraph::Forgetting.stub(:key, nil) do
        assert_raises(Operations::Base::ParameterError) do
          call(Operations::Tenants::EnableScheduledForgetting, confirm_count: 1)
        end
      end
      assert_not config.scheduled_forgetting
    end

    should "refuse while the tenant keeps leavers for ever" do
      @tenant.update!(org_graph_config: { retention_years: nil })

      assert_raises(Operations::Base::ParameterError) do
        call(Operations::Tenants::EnableScheduledForgetting, confirm_count: 0)
      end
    end

    should "refuse anyone but a tenant admin" do
      assert_raises(Pundit::NotAuthorizedError) do
        call(Operations::Tenants::EnableScheduledForgetting, context: as(:member), confirm_count: 1)
      end
    end
  end

  context "turning the schedule off" do
    should "stop the schedule and forget who turned it on" do
      call(Operations::Tenants::EnableScheduledForgetting, confirm_count: 1)

      assert_equal({ tenant_id: @tenant.id, scheduled_forgetting: false },
        call(Operations::Tenants::DisableScheduledForgetting))
      assert_not config.scheduled_forgetting
      assert_nil config.scheduled_forgetting_enabled_by_id
    end

    should "refuse anyone but a tenant admin" do
      assert_raises(Pundit::NotAuthorizedError) do
        call(Operations::Tenants::DisableScheduledForgetting, context: as(:member))
      end
    end
  end
end
