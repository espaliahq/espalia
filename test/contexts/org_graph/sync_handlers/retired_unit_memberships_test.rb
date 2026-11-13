# frozen_string_literal: true

require "test_helper"

class OrgGraph::SyncHandlers::RetiredUnitMembershipsTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @structure = OrgGraph::StructureCommandHandler.new
    @people = OrgGraph::CommandHandler.new
    @department_level = SecureRandom.uuid_v7
    @team_level = SecureRandom.uuid_v7
    @engineering, @payments, @billing, @ledger = Array.new(4) { SecureRandom.uuid_v7 }

    as_tenant do
      @ada, @grace = create_list(:person, 2, tenant: @tenant)
      @structure.define_taxonomy([ { level_id: @department_level, name: "Department" },
                                   { level_id: @team_level, name: "Team" } ], effective_on: "2026-01-01")
      @structure.create_unit(@engineering, "Engineering", level_id: @department_level, effective_on: "2026-01-01")
      [ [ @payments, "Payments" ], [ @billing, "Billing" ], [ @ledger, "Ledger" ] ].each do |id, name|
        @structure.create_unit(id, name, level_id: @team_level, parent_id: @engineering, effective_on: "2026-01-01")
      end
      [ @ada, @grace ].each { |person| @people.record_person(person.id, **ESPALIA, employment_status: "employed") }
      @people.set_membership(@ada.id, @payments, allocation: 0.6, role: "Tech lead", **ESPALIA)
      @people.set_membership(@grace.id, @payments, **ESPALIA)
      @people.set_membership(@grace.id, @billing, **ESPALIA)
    end
  end

  ESPALIA = { provider: "espalia", effective_on: "2026-02-01" }.freeze

  context "a plain retirement" do
    setup { as_tenant { @structure.retire_unit(@payments, effective_on: "2026-06-30", retired_by_id: @ada.id) } }

    should "end every open membership in the unit on the retirement date, in each member's stream" do
      [ @ada, @grace ].each do |person|
        ended = person_events(person).select { |event| event.is_a?(OrgGraph::Events::MembershipEnded) }.sole
        assert_equal [ @payments, "2026-06-30", @ada.id ], ended.data.values_at(:unit_id, :effective_on, :ended_by_id)
      end
      as_tenant { assert_not OrgMembership.exists?(unit_id: @payments) }
    end

    should "end each membership as its provider, leaving the person's other memberships" do
      grace_ended = person_events(@grace).find { |event| event.is_a?(OrgGraph::Events::MembershipEnded) }

      assert_equal "espalia", grace_ended.data[:provider]
      as_tenant { assert OrgMembership.exists?(person_id: @grace.id, unit_id: @billing) }
    end

    should "carry the retirement as each change's cause" do
      retirement = structure_events.reverse.find { |event| event.is_a?(OrgGraph::Events::UnitRetired) }
      ended = [ @ada, @grace ].map { |person| person_events(person).last }

      assert(ended.all? { |event| event.metadata[:causation_id] == retirement.event_id })
      assert(ended.all? { |event| event.metadata[:correlation_id] == retirement.metadata[:correlation_id] })
    end
  end

  should "roll the retirement back with every membership change when one member's change fails" do
    commands = OrgGraph::CommandHandler.new
    calls = 0
    failing_second = commands.method(:end_membership)
    commands.define_singleton_method(:end_membership) do |*args, **options|
      raise "member command failed" if (calls += 1) == 2

      failing_second.call(*args, **options)
    end

    OrgGraph::CommandHandler.stub(:new, commands) do
      assert_raises(RuntimeError, match: /member command failed/) do
        as_tenant { @structure.retire_unit(@payments, effective_on: "2026-06-30") }
      end
    end

    assert_not(structure_events.any? { |event| event.is_a?(OrgGraph::Events::UnitRetired) })
    assert_not([ @ada, @grace ].any? { |person| person_events(person).any?(OrgGraph::Events::MembershipEnded) })
    as_tenant { assert_equal 2, OrgMembership.where(unit_id: @payments).count }
  end

  should "close a membership that began after a backdated retirement on the day it began" do
    as_tenant do
      @people.set_membership(@ada.id, @ledger, **ESPALIA, effective_on: "2026-09-01")
      @structure.retire_unit(@ledger, effective_on: "2026-08-01")
    end

    assert_equal "2026-09-01", person_events(@ada).last.data[:effective_on]
  end

  should "close a membership whose terms changed after a backdated retirement on the day they changed" do
    as_tenant do
      @people.set_membership(@ada.id, @payments, allocation: 0.4, **ESPALIA, effective_on: "2026-09-01")
      @people.set_membership(@grace.id, @payments, allocation: 0.4, **ESPALIA, effective_on: "2026-08-15")
      @structure.retire_unit(@payments, effective_on: "2026-08-01")
    end

    assert_equal "2026-09-01", person_events(@ada).last.data[:effective_on]
    assert_equal "2026-08-15", person_events(@grace).last.data[:effective_on]
  end

  should "close a membership after its latest change when a later one was backdated" do
    as_tenant do
      @people.set_membership(@ada.id, @payments, allocation: 0.4, **ESPALIA, effective_on: "2026-09-01")
      @people.set_membership(@ada.id, @payments, allocation: 0.3, **ESPALIA, effective_on: "2026-08-10")
      @structure.retire_unit(@payments, effective_on: "2026-08-20")
    end

    ended = person_events(@ada).last
    assert_kind_of OrgGraph::Events::MembershipEnded, ended
    assert_equal "2026-09-01", ended.data[:effective_on]
  end

  context "a retirement through a succession" do
    should "move every member to the one successor of a merge, writing no MembershipEnded" do
      as_tenant do
        @structure.record_succession(SecureRandom.uuid_v7, predecessor_ids: [ @payments, @ledger ], successor_ids: [ @billing ],
                                                           effective_on: "2026-07-01", retire_predecessors: true)
      end

      ada_moved = person_events(@ada).last
      assert_kind_of OrgGraph::Events::MembershipMoved, ada_moved
      assert_equal [ @payments, @billing, 0.6, "Tech lead", "2026-07-01" ],
                   ada_moved.data.values_at(:from_unit_id, :unit_id, :allocation, :role, :effective_on)
      assert_not(person_events(@ada).any?(OrgGraph::Events::MembershipEnded))
      as_tenant do
        assert_equal [ @ada.id, @grace.id ].sort, OrgUnit.find(@billing).members.pluck(:id).sort
        assert_empty OrgUnit.find(@payments).members
      end
    end

    should "keep how long each member has been in the team" do
      as_tenant do
        @structure.record_succession(SecureRandom.uuid_v7, predecessor_ids: [ @payments ], successor_ids: [ @ledger ],
                                                           effective_on: "2026-07-01", retire_predecessors: true)

        assert_equal Date.new(2026, 2, 1), OrgMembership.find_by!(person_id: @ada.id, unit_id: @ledger).member_since
      end
    end

    should "end, not move, the membership of someone who has left" do
      as_tenant do
        @people.leave(@ada.id, provider: "espalia", effective_on: "2026-05-31")
        @structure.record_succession(SecureRandom.uuid_v7, predecessor_ids: [ @payments ], successor_ids: [ @ledger ],
                                                           effective_on: "2026-07-01", retire_predecessors: true)

        assert_kind_of OrgGraph::Events::MembershipEnded, person_events(@ada).last
        assert_not OrgMembership.exists?(person_id: @ada.id, unit_id: @ledger)
      end
    end

    should "keep a member's place in the successor when they are already in it" do
      as_tenant do
        @structure.record_succession(SecureRandom.uuid_v7, predecessor_ids: [ @payments ], successor_ids: [ @billing ],
                                                           effective_on: "2026-07-01", retire_predecessors: true)
      end

      as_tenant { assert_equal [ @billing ], OrgMembership.where(person_id: @grace.id).pluck(:unit_id) }
    end

    should "in a split, move the people named first and end the rest" do
      as_tenant do
        @people.move_membership(@ada.id, @payments, @ledger, effective_on: "2026-07-01")
        @structure.record_succession(SecureRandom.uuid_v7, predecessor_ids: [ @payments ], successor_ids: [ @billing, @ledger ],
                                                           effective_on: "2026-07-01", retire_predecessors: true)
      end

      assert_kind_of OrgGraph::Events::MembershipMoved, person_events(@ada).last
      grace_ended = person_events(@grace).last
      assert_kind_of OrgGraph::Events::MembershipEnded, grace_ended
      assert_equal @payments, grace_ended.data[:unit_id]
      as_tenant { assert_equal [ @ada.id ], OrgUnit.find(@ledger).members.pluck(:id) }
    end
  end

  should "still refuse to retire a unit with live children, leaving its members in place" do
    as_tenant do
      @people.set_membership(@ada.id, @engineering, **ESPALIA)

      assert_raises(RuntimeError) { @structure.retire_unit(@engineering, effective_on: "2026-06-30") }
      assert OrgMembership.exists?(person_id: @ada.id, unit_id: @engineering)
    end
  end

  private

  def as_tenant(&block)
    ActsAsTenant.with_tenant(@tenant, &block)
  end

  def person_events(person)
    Rails.configuration.event_store.read.stream(EventStreamNaming.person_stream(person.id, tenant: @tenant)).to_a
  end

  def structure_events
    Rails.configuration.event_store.read.stream(EventStreamNaming.org_structure_stream(tenant: @tenant)).to_a
  end
end
