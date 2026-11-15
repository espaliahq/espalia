# frozen_string_literal: true

require "test_helper"

class TeamPlanning::SourceOfTruthTest < ActiveSupport::TestCase
  SYSTEM = OrgGraph::Authorization::SYSTEM

  setup do
    @tenant = create(:tenant)
    @department, @team = Array.new(2) { SecureRandom.uuid_v7 }
    @sales, @payments, @billing = Array.new(3) { SecureRandom.uuid_v7 }
    @split = SecureRandom.uuid_v7
    ActsAsTenant.with_tenant(@tenant) do
      structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
      structure.define_taxonomy([ { level_id: @department, name: "Department", provider: "hibob" },
                                  { level_id: @team, name: "Team" } ], effective_on: "2026-01-01")
      structure.create_unit(@sales, "Sales", level_id: @department, provider: "hibob", external_ref: "dept-1", effective_on: "2026-01-01")
      structure.create_unit(@payments, "Payments", level_id: @team, effective_on: "2026-01-01")
      structure.create_unit(@billing, "Billing", level_id: @team, effective_on: "2026-01-01")
      structure.record_succession(@split, predecessor_ids: [ @payments ], successor_ids: [ @billing ], effective_on: "2026-02-01")
      structure.set_fact_provider("level", "hibob", effective_on: "2026-01-01")
    end
    @sources = TeamPlanning::SourceOfTruth.new(tenant_id: @tenant.id)
  end

  def change(kind, **fields)
    OrgGraph::ChangesBetween::Change.new(kind:, effective_on: Date.new(2026, 3, 1), learned_at: Time.current, person_id: nil,
                                         unit_id: nil, from_unit_id: nil, succession_id: nil, fact: nil, before: nil,
                                         after: nil, provider: "espalia", event_id: SecureRandom.uuid, withdrawn: false, **fields)
  end

  context "a person fact" do
    should "come from the provider chosen for it, and from Espalia where nobody chose" do
      assert_equal %w[hibob], @sources.of_drift(change(:fact_changed, fact: "level"))
      assert_equal %w[espalia], @sources.of_drift(change(:fact_changed, fact: "title"))
      assert_equal %w[espalia], @sources.of_drift(change(:joined))
      assert_equal %w[hibob], @sources.of_plan("level")
      assert_equal %w[espalia], @sources.of_plan("reporting_line")
    end
  end

  context "a membership, a unit or a succession" do
    should "come from whoever supplied the membership, as Espalia can hold one in a mirrored unit" do
      assert_equal %w[espalia], @sources.of_drift(change(:membership_started, unit_id: @sales))
      assert_equal %w[hibob], @sources.of_drift(change(:moved, unit_id: @payments, from_unit_id: @sales, provider: "hibob"))
    end

    should "come from the providers of the units it touches" do
      assert_equal %w[hibob], @sources.of_drift(change(:unit_renamed, unit_id: @sales))
      assert_equal %w[espalia], @sources.of_drift(change(:unit_succeeded, succession_id: @split))
      assert_equal %w[hibob], @sources.of_plan("assignment", unit_ids: [ @sales, @sales ])
    end

    should "be Espalia's for a unit only the plan holds" do
      assert_equal %w[espalia], @sources.of_plan("unit", unit_ids: [ SecureRandom.uuid_v7 ])
      assert_equal %w[espalia], @sources.of_plan("assignment")
    end
  end

  should "read a list's units and successions once, ahead of its changes" do
    assert_queries_count(2) { @sources.preload(unit_ids: [ @sales, @payments ], succession_ids: [ @split ]) }
    assert_no_queries do
      assert_equal %w[espalia hibob], @sources.of_drift(change(:unit_moved, unit_id: @sales, from_unit_id: @billing))
      assert_equal %w[espalia], @sources.of_drift(change(:unit_succeeded, succession_id: @split))
    end
    assert_equal "Sales", @sources.unit_name(@sales)
  end

  should "remember a unit only the plan holds, so it reads that unit once" do
    plan_only = SecureRandom.uuid_v7
    assert_queries_count(1) { @sources.preload(unit_ids: [ plan_only ]) }
    assert_no_queries { assert_equal %w[espalia], @sources.of_plan("unit", unit_ids: [ plan_only ]) }
  end
end
