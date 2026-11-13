# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/projection_replay"

class OrgGraph::Projections::UnitActivityTest < ActiveSupport::TestCase
  include ProjectionReplayHelpers

  ESPALIA = { provider: "espalia", effective_on: "2026-02-01" }.freeze
  START = Time.zone.parse("2026-02-01 09:00")

  setup do
    @tenant = create(:tenant)
    @handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    @structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    @departments, @squads = SecureRandom.uuid_v7, SecureRandom.uuid_v7
    @payments, @platform = SecureRandom.uuid_v7, SecureRandom.uuid_v7

    travel_to START
    as_tenant do
      @ada, @lead = create_list(:person, 2, tenant: @tenant)
      @structure.define_taxonomy([ { level_id: @departments, name: "Department" }, { level_id: @squads, name: "Squad" } ], effective_on: "2026-01-01")
      @structure.create_unit(@payments, "Payments", level_id: @squads, effective_on: "2026-01-01", created_by_id: @lead.id)
      @structure.create_unit(@platform, "Platform", level_id: @squads, effective_on: "2026-01-01")
      [ @ada, @lead ].each { |person| @handler.record_person(person.id, **ESPALIA, employment_status: "employed") }
    end
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def feed(unit_id)
    as_tenant { OrgUnitActivity.for_unit(unit_id).to_a }
  end

  should "list a unit's changes newest first, saying who, what, and when it took effect and was learned" do
    travel_to START + 1.day
    as_tenant do
      @handler.set_membership(@ada.id, @payments, **ESPALIA, allocation: 1.0, set_by_id: @lead.id)
      @structure.rename_unit(@payments, "Payments Core", effective_on: "2026-01-15", renamed_by_id: @lead.id)
    end

    renamed, set, created = feed(@payments)
    assert_equal %w[UnitRenamed MembershipSet UnitCreated], [ renamed, set, created ].map(&:event_type)
    assert_equal [ @lead.id, "espalia", Date.new(2026, 1, 15), START + 1.day ],
      [ renamed.actor_id, renamed.provider, renamed.effective_on, renamed.learned_at ]
    assert_equal [ { "name" => "Payments" }, { "name" => "Payments Core" } ], [ renamed.before, renamed.after ]
    assert_equal [ nil, { "allocation" => 1.0, "role" => nil } ], [ set.before, set.after ]
    assert_equal [ @ada.id, "membership:#{@ada.id}" ], [ set.person_id, set.subject ]
    assert_equal @lead.id, created.actor_id
  end

  should "carry a membership's earlier terms into its next change and its end" do
    as_tenant do
      @handler.set_membership(@ada.id, @payments, **ESPALIA, allocation: 1.0)
      @handler.set_membership(@ada.id, @payments, **ESPALIA, allocation: 0.5, role: "Lead")
      @handler.end_membership(@ada.id, @payments, **ESPALIA)
    end

    ended, changed, = feed(@payments)
    assert_equal [ { "allocation" => 1.0, "role" => nil }, { "allocation" => 0.5, "role" => "Lead" } ],
      [ changed.before, changed.after ]
    assert_equal [ { "allocation" => 0.5, "role" => "Lead" }, nil ], [ ended.before, ended.after ]
  end

  should "show a move in both units, each naming the other" do
    as_tenant do
      @handler.set_membership(@ada.id, @payments, **ESPALIA, allocation: 1.0)
      @handler.move_membership(@ada.id, @payments, @platform, effective_on: "2026-02-01", moved_by_id: @lead.id)
    end

    left, arrived = feed(@payments).first, feed(@platform).first
    assert_equal [ "MembershipMoved", @platform, { "allocation" => 1.0, "role" => nil }, nil ],
      [ left.event_type, left.other_unit_id, left.before, left.after ]
    assert_equal [ @payments, nil, { "allocation" => 1.0, "role" => nil } ],
      [ arrived.other_unit_id, arrived.before, arrived.after ]
    assert_equal [ @lead.id, @lead.id ], [ left.actor_id, arrived.actor_id ]
    assert_equal left.event_id, arrived.event_id
  end

  should "record owners with no provider, as their events carry none, and unit moves with the parent they left" do
    engineering = SecureRandom.uuid_v7
    as_tenant do
      @structure.create_unit(engineering, "Engineering", level_id: @departments, effective_on: "2026-01-01")
      @structure.add_unit_owner(@payments, @lead.id, effective_on: "2026-02-01", added_by_id: @ada.id)
      @structure.move_unit(@payments, engineering, effective_on: "2026-02-01")
    end

    moved, owned, = feed(@payments)
    assert_equal [ "parent", { "parent_id" => nil }, { "parent_id" => engineering } ], [ moved.subject, moved.before, moved.after ]
    assert_equal [ "owner:#{@lead.id}", @lead.id, nil, @ada.id ],
      [ owned.subject, owned.person_id, owned.provider, owned.actor_id ]
  end

  should "show a succession in every unit it names, and keep each entry's cause" do
    successor = SecureRandom.uuid_v7
    as_tenant do
      @handler.set_membership(@ada.id, @payments, **ESPALIA)
      @structure.create_unit(successor, "Payments Next", level_id: @squads, effective_on: "2026-02-01")
      @structure.record_succession(SecureRandom.uuid_v7, predecessor_ids: [ @payments ], successor_ids: [ successor ],
        effective_on: "2026-02-02", retire_predecessors: true)
    end

    assert_equal %w[MembershipMoved UnitSucceeded UnitCreated], feed(successor).map(&:event_type)
    types = feed(@payments).map(&:event_type)
    assert_includes types, "UnitSucceeded"
    assert_includes types, "UnitRetired"

    retired = feed(@payments).find { |entry| entry.event_type == "UnitRetired" }
    moved = feed(@payments).find { |entry| entry.event_type == "MembershipMoved" }
    assert_equal [ retired.event_id, successor ], [ moved.causation_id, moved.other_unit_id ]
  end

  should "know whether an entry is still its fact's latest change" do
    as_tenant do
      @handler.set_membership(@ada.id, @payments, **ESPALIA)
      @handler.set_membership(@lead.id, @payments, **ESPALIA)
    end

    lead, ada, = feed(@payments)
    assert lead.latest?
    assert ada.latest?

    as_tenant { @handler.end_membership(@ada.id, @payments, **ESPALIA) }
    assert_not ada.latest?
  end

  context "rebuild contract" do
    should "reset! + replay produce identical read-model state, including the stable ids" do
      as_tenant do
        @handler.set_membership(@ada.id, @payments, **ESPALIA, allocation: 1.0)
        @handler.set_membership(@ada.id, @payments, **ESPALIA, allocation: 0.5)
        @handler.move_membership(@ada.id, @payments, @platform, effective_on: "2026-02-03")
        @structure.rename_unit(@platform, "Platform Core", effective_on: "2026-02-03")
      end

      other = create(:tenant)
      ActsAsTenant.with_tenant(other) do
        OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
          .define_taxonomy([ { level_id: SecureRandom.uuid_v7, name: "Team" } ], effective_on: "2026-01-01")
      end
      ActsAsTenant.with_tenant(other) do
        level = OrgTaxonomyLevel.pick(:id)
        OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
          .create_unit(SecureRandom.uuid_v7, "Elsewhere", level_id: level, effective_on: "2026-01-01")
      end

      before = snapshot_read_models(OrgGraph::Projections::UnitActivity, @tenant)
      assert_equal 7, before[:unit_activities].size

      OrgGraph::Projections::UnitActivity.reset!(tenant: @tenant)
      as_tenant { assert_equal 0, OrgUnitActivity.count }
      ActsAsTenant.with_tenant(other) { assert_equal 1, OrgUnitActivity.count }

      Projections::Replayer.replay(projection_class: OrgGraph::Projections::UnitActivity, tenant: @tenant)

      assert_equal before, snapshot_read_models(OrgGraph::Projections::UnitActivity, @tenant)
    end
  end
end
