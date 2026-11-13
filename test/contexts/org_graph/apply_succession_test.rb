# frozen_string_literal: true

require "test_helper"

class OrgGraph::ApplySuccessionTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia", effective_on: "2026-02-01" }.freeze
  PLAN = { plan_id: "plan-7", plan_change_id: "change-3" }.freeze

  setup do
    @tenant = create(:tenant)
    @system = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    @people = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    @department_level, @team_level = Array.new(2) { SecureRandom.uuid_v7 }
    @engineering, @payments, @billing, @ledger, @product = Array.new(5) { SecureRandom.uuid_v7 }

    as_tenant do
      @ada, @grace, @linus, @approver = create_list(:person, 4, tenant: @tenant)
      @system.define_taxonomy([ { level_id: @department_level, name: "Department" },
                                { level_id: @team_level, name: "Team" } ], effective_on: "2026-01-01")
      @system.create_unit(@engineering, "Engineering", level_id: @department_level, effective_on: "2026-01-01")
      @system.create_unit(@product, "Product", level_id: @department_level, effective_on: "2026-01-01")
      [ [ @payments, "Payments" ], [ @billing, "Billing" ], [ @ledger, "Ledger" ] ].each do |id, name|
        @system.create_unit(id, name, level_id: @team_level, parent_id: @engineering, effective_on: "2026-01-01")
      end
      [ @ada, @grace, @linus, @approver ].each do |person|
        @people.record_person(person.id, **ESPALIA, employment_status: "employed")
      end
      [ @ada, @grace, @linus ].each { |person| @people.set_membership(person.id, @payments, **ESPALIA) }
      @system.add_unit_owner(@engineering, @approver.id, effective_on: "2026-01-01")
    end
  end

  context "an approved split" do
    setup do
      @written = written_during do
        apply_as(approver, predecessor_ids: [ @payments ], successor_ids: [ @billing, @ledger ],
                           placements: { @ada.id => @billing, @grace.id => @ledger })
      end
    end

    should "move the people it names to their successors" do
      as_tenant do
        assert_equal [ @ada.id ], OrgUnit.find(@billing).members.pluck(:id)
        assert_equal [ @grace.id ], OrgUnit.find(@ledger).members.pluck(:id)
      end
    end

    should "end the membership of anyone it doesn't name" do
      ended = person_events(@linus).last
      assert_instance_of OrgGraph::Events::MembershipEnded, ended
      assert_equal [ @payments, "2026-07-01" ], ended.data.values_at(:unit_id, :effective_on)
    end

    should "state the succession and retire the predecessor" do
      assert_equal [ OrgGraph::Events::UnitSucceeded, OrgGraph::Events::UnitRetired ], structure_events.last(2).map(&:class)
      assert_equal [ @billing, @ledger ].sort, structure_events.last(2).first.data[:successor_ids]
      as_tenant { assert OrgUnit.find(@payments).retired? }
    end

    should "write every event under the approval and the plan change, naming the approver" do
      assert_equal 5, @written.size
      assert_equal [ "approval-1" ], @written.map { |event| event.metadata[:correlation_id] }.uniq
      assert(@written.all? { |event| event.data.slice(:plan_id, :plan_change_id) == PLAN })
      assert_equal [ @approver.id ] * 2, person_events(@ada, @grace).map { |events| events.last.data[:moved_by_id] }
      assert_equal @approver.id, structure_events.last(2).first.data[:stated_by_id]
    end
  end

  context "an approved merge" do
    should "move every member to the one successor" do
      as_tenant { @people.set_membership(@ada.id, @ledger, **ESPALIA) }

      apply_as(approver, predecessor_ids: [ @payments, @ledger ], successor_ids: [ @billing ])

      as_tenant do
        assert_equal [ @ada.id, @grace.id, @linus.id ].sort, OrgUnit.find(@billing).members.pluck(:id).sort
        assert(OrgUnit.where(id: [ @payments, @ledger ]).all?(&:retired?))
      end
      assert_not(person_events(@grace).any?(OrgGraph::Events::MembershipEnded))
    end
  end

  context "a succession that can't be applied" do
    should "write nothing when the approver may not change every unit in it" do
      assert_writes_nothing(OrgGraph::Authorization::Refused) do
        apply_as(approver, predecessor_ids: [ @payments ], successor_ids: [ @billing, @product ],
                           placements: { @ada.id => @billing })
      end
    end

    should "write nothing when a placement names a unit outside the successors" do
      assert_writes_nothing(ArgumentError) do
        apply_as(approver, predecessor_ids: [ @payments ], successor_ids: [ @billing, @ledger ],
                           placements: { @ada.id => @billing, @grace.id => @product })
      end
    end

    should "write nothing when a placement names someone in no predecessor" do
      assert_writes_nothing(ArgumentError) do
        apply_as(approver, predecessor_ids: [ @payments ], successor_ids: [ @billing, @ledger ],
                           placements: { @ada.id => @billing, @approver.id => @ledger })
      end
    end

    should "undo the placements when the succession itself is refused" do
      taken = SecureRandom.uuid_v7
      as_tenant do
        @system.record_succession(taken, predecessor_ids: [ @ledger ], successor_ids: [ @billing ], effective_on: "2026-03-01")
      end

      assert_writes_nothing(RuntimeError) do
        apply_as(approver, succession_id: taken, predecessor_ids: [ @payments ], successor_ids: [ @billing, @ledger ],
                           placements: { @ada.id => @billing })
      end
    end
  end

  private

  def approver
    as_tenant do
      user = create(:user)
      tenant_user = create(:tenant_user, tenant: @tenant, user:, person: @approver, role: :member)
      AuthorizationContext.new(user:, tenant_user:, person: @approver)
    end
  end

  def apply_as(actor, succession_id: SecureRandom.uuid_v7, effective_on: "2026-07-01", **succession)
    handler = OrgGraph::StructureCommandHandler.new(actor:, cause_id: "approval-1")
    as_tenant { handler.apply_succession(succession_id, effective_on:, **succession, **PLAN) }
  end

  def written_during
    before = event_store.read.to_a.map(&:event_id)
    yield
    event_store.read.to_a.reject { |event| before.include?(event.event_id) }
  end

  def assert_writes_nothing(error, &block)
    written = written_during { assert_raises(error, &block) }
    assert_empty written
    as_tenant { assert_equal [ @ada.id, @grace.id, @linus.id ].sort, OrgUnit.find(@payments).members.pluck(:id).sort }
  end

  def as_tenant(&block)
    ActsAsTenant.with_tenant(@tenant, &block)
  end

  def event_store = Rails.configuration.event_store

  def person_events(*people)
    streams = people.map { |person| event_store.read.stream(EventStreamNaming.person_stream(person.id, tenant: @tenant)).to_a }
    people.one? ? streams.first : streams
  end

  def structure_events
    event_store.read.stream(EventStreamNaming.org_structure_stream(tenant: @tenant)).to_a
  end
end
