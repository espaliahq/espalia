# frozen_string_literal: true

require "test_helper"

# Team Planning 8.3 (#193): the Org Graph writes a plan change can make take
# its plan reference and cause, and refuse a reference the caller can't use.
class Operations::OrgGraph::PlanReferenceTest < ActiveSupport::TestCase
  include OrgGraphFixture

  PLAN_OPERATIONS = [
    Operations::OrgGraph::RenameUnit, Operations::OrgGraph::MoveUnit, Operations::OrgGraph::RetireUnit,
    Operations::OrgGraph::SplitUnit, Operations::OrgGraph::MergeUnit, Operations::OrgGraph::AddMember,
    Operations::OrgGraph::MoveMember, Operations::OrgGraph::RemoveMember
  ].freeze

  setup do
    @tenant = create(:tenant)
    @org = build_org_graph(@tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @admin = create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant))
    end
    @plan_id = SecureRandom.uuid_v7
    @plan_change_id = SecureRandom.uuid_v7
    @cause_id = SecureRandom.uuid_v7
  end

  def call(operation, **params)
    ActsAsTenant.with_tenant(@tenant) do
      context = AuthorizationContext.new(user: @admin.user, tenant_user: @admin, person: @admin.person)
      operation.call(context: context, params: params)
    end
  end

  def with_plan_access(&) = Operations::OrgGraph::PlanWrite.stub(:may_apply?, true, &)

  def rename(**plan) = call(Operations::OrgGraph::RenameUnit, unit_id: @org[:platform], name: "Core", **plan)

  def unit_name = ActsAsTenant.with_tenant(@tenant) { OrgUnit.find(@org[:platform]).name }

  def events_since(position)
    Rails.configuration.event_store.read.to_a.drop(position)
  end

  should "take a plan reference on every write a plan change makes, and on no other" do
    takes_plan = Operations::Registry.all.select { it.parameters.key?(:plan_id) }

    assert_equal PLAN_OPERATIONS.map(&:name).sort, takes_plan.map(&:name).sort
    PLAN_OPERATIONS.each do |operation|
      assert_equal %i[plan_change_id cause_id].sort,
                   operation.dependent_requirements.select { it.requires == :plan_id }.map(&:dependent).sort
    end
  end

  should "leave a direct edit unattributed, under its own cause" do
    rename
    call(Operations::OrgGraph::RenameUnit, unit_id: @org[:checkout], name: "Till")

    first, second = Rails.configuration.event_store.read.of_type(OrgGraph::Events::UnitRenamed).to_a.last(2)
    assert_nil first.data[:plan_id]
    assert_nil first.data[:plan_change_id]
    assert_not_equal first.metadata[:correlation_id], second.metadata[:correlation_id]
  end

  context "until plans exist" do
    should "refuse every plan reference, as it would a plan the caller can't see" do
      error = assert_raises(Operations::Base::ParameterError) { rename(plan_id: @plan_id) }

      assert_equal "plan_id names no plan whose changes you may apply", error.message
      assert_equal "Platform", unit_name
    end
  end

  context "with a plan the caller may apply" do
    should "stamp the plan reference and cause on the events, and show the plan in the activity feed" do
      before = Rails.configuration.event_store.read.count
      with_plan_access do
        rename(plan_id: @plan_id.upcase, plan_change_id: @plan_change_id, cause_id: @cause_id)
      end

      event = events_since(before).find { it.is_a?(OrgGraph::Events::UnitRenamed) }
      assert_equal @plan_id, event.data[:plan_id]
      assert_equal @plan_change_id, event.data[:plan_change_id]
      assert_equal @cause_id, event.metadata[:correlation_id]
      group = call(Operations::OrgGraph::Activity, unit_id: @org[:platform])[:groups].first
      assert_equal [ @cause_id, @plan_id, @plan_change_id ], group.values_at(:cause_id, :plan_id, :plan_change_id)
    end

    should "carry the plan's cause through every event a merge writes" do
      before = Rails.configuration.event_store.read.count
      with_plan_access do
        call(Operations::OrgGraph::MergeUnit, unit_id: @org[:payments], into_unit_id: @org[:checkout],
                                              plan_id: @plan_id, plan_change_id: @plan_change_id, cause_id: @cause_id)
      end

      written = events_since(before)
      assert written.size > 1
      assert_equal [ @cause_id ], written.map { it.metadata[:correlation_id] }.uniq
      assert_equal [ @plan_id ], written.map { it.data[:plan_id] }.uniq
    end

    should "carry the plan through a split, its leavers' ended memberships included" do
      before = Rails.configuration.event_store.read.count
      with_plan_access do
        call(Operations::OrgGraph::SplitUnit, unit_id: @org[:platform], successor_names: %w[Core Edge],
                                              placements: { @org[:ada].id => "Core" },
                                              plan_id: @plan_id, plan_change_id: @plan_change_id, cause_id: @cause_id)
      end

      written = events_since(before)
      assert_includes written.map(&:class), OrgGraph::Events::MembershipEnded
      assert_equal [ @cause_id ], written.map { it.metadata[:correlation_id] }.uniq
      assert_equal [ [ @plan_id, @plan_change_id ] ], written.map { it.data.values_at(:plan_id, :plan_change_id) }.uniq
    end

    should "stamp the reference on a membership a plan places" do
      before = Rails.configuration.event_store.read.count
      with_plan_access do
        call(Operations::OrgGraph::AddMember, unit_id: @org[:platform], person_id: @org[:ezra].id,
                                              plan_id: @plan_id, plan_change_id: @plan_change_id)
      end

      assert_equal [ @plan_id ], events_since(before).map { it.data[:plan_id] }.uniq
    end

    should "refuse a malformed id" do
      with_plan_access do
        assert_raises(Operations::Base::ParameterError) { rename(plan_id: "plan-1") }
        assert_raises(Operations::Base::ParameterError) { rename(plan_id: @plan_id, cause_id: "not-a-uuid") }
      end
      assert_equal "Platform", unit_name
    end

    should "refuse a cause that already groups changes from no plan, or from another plan" do
      rename_cause = ->(plan_id) { with_plan_access { rename(plan_id:, cause_id: @cause_id) } }
      ActsAsTenant.with_tenant(@tenant) do
        OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM, cause_id: @cause_id)
                                         .rename_unit(@org[:checkout], "Till", effective_on: "2026-02-01")
      end

      error = assert_raises(Operations::Base::ParameterError) { rename_cause.call(@plan_id) }
      assert_equal "cause_id already groups changes that aren't from this plan", error.message

      other_cause = @cause_id = SecureRandom.uuid_v7
      with_plan_access { rename(plan_id: SecureRandom.uuid_v7, cause_id: other_cause) }
      assert_raises(Operations::Base::ParameterError) { rename_cause.call(@plan_id) }
      assert_equal "Core", unit_name
    end

    should "let a plan's changes share its cause" do
      with_plan_access do
        rename(plan_id: @plan_id, plan_change_id: SecureRandom.uuid_v7, cause_id: @cause_id)
        call(Operations::OrgGraph::RenameUnit, unit_id: @org[:checkout], name: "Till",
                                               plan_id: @plan_id, plan_change_id: SecureRandom.uuid_v7, cause_id: @cause_id)
      end

      assert_equal 2, ActsAsTenant.with_tenant(@tenant) { OrgUnitActivity.caused_by(@cause_id).count }
    end
  end

  should "refuse a plan_change_id or cause_id without a plan_id" do
    assert_raises(Operations::Base::ParameterError) { rename(plan_change_id: @plan_change_id) }
    assert_raises(Operations::Base::ParameterError) { rename(cause_id: @cause_id) }
    assert_equal "Platform", unit_name
  end
end
