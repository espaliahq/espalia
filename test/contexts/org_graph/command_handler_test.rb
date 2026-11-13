# frozen_string_literal: true

require "test_helper"

class OrgGraph::CommandHandlerTest < ActiveSupport::TestCase
  PROVENANCE = { provider: "hibob", effective_on: "2026-11-01" }.freeze
  HELD_BY_ESPALIA = { provider: "espalia", effective_on: "2026-11-01" }.freeze

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @handler = OrgGraph::CommandHandler.new
    @person_id = SecureRandom.uuid_v7
    OrgGraph::StructureCommandHandler.new.claim_facts(OrgGraph::StructureAggregate::FACTS, "hibob", effective_on: "2026-01-01")
  end

  teardown do
    ActsAsTenant.current_tenant = nil
  end

  def stream_events
    Rails.configuration.event_store.read.stream(EventStreamNaming.person_stream(@person_id)).to_a
  end

  should "write each command to the person's stream with the tenant in its metadata" do
    @handler.record_person(@person_id, **PROVENANCE, employment_status: "pending", title: "Engineer")
    @handler.join(@person_id, **PROVENANCE)
    @handler.change_employment(@person_id, fte: 0.5, employment_type: "Part time", **PROVENANCE)

    events = stream_events
    assert_equal [ OrgGraph::Events::PersonRecorded, OrgGraph::Events::PersonJoined, OrgGraph::Events::EmploymentChanged ],
      events.map(&:class)
    assert(events.all? { |event| event.metadata[:tenant_id] == @tenant.id })
    assert_in_delta 0.5, events.last.data[:fte]
  end

  should "rebuild the person from their stream, so an unchanged fact writes nothing" do
    manager_id = SecureRandom.uuid_v7
    @handler.record_person(@person_id, **PROVENANCE, employment_status: "employed", title: "Engineer",
      manager_id: manager_id, site: "Sydney", country: "Australia", fte: 1, employment_type: "Permanent")
    @handler.change_title(@person_id, "Senior Engineer", **PROVENANCE)
    @handler.leave(@person_id, **PROVENANCE)

    @handler.change_title(@person_id, "Senior Engineer", **PROVENANCE)
    @handler.change_manager(@person_id, manager_id, **PROVENANCE)
    @handler.change_site(@person_id, site: "Sydney", country: "Australia", **PROVENANCE)
    @handler.change_employment(@person_id, fte: 1, employment_type: "Permanent", **PROVENANCE)
    @handler.leave(@person_id, **PROVENANCE)

    assert_equal 3, stream_events.size
  end

  context "#sync_person" do
    should "record a new person, then write only what changed" do
      first = @handler.sync_person(@person_id, **PROVENANCE, employment_status: "employed", title: "Engineer")
      repeat = @handler.sync_person(@person_id, **PROVENANCE, employment_status: "employed", title: "Engineer")
      changed = @handler.sync_person(@person_id, **PROVENANCE, employment_status: "employed", title: "Lead")

      assert_equal [ 1, 0, 1 ], [ first, repeat, changed ]
      assert_equal [ OrgGraph::Events::PersonRecorded, OrgGraph::Events::TitleChanged ], stream_events.map(&:class)
    end

    should "record a leaver once and leave their facts alone after" do
      @handler.sync_person(@person_id, **PROVENANCE, employment_status: "left", title: "Engineer")

      assert_equal 0, @handler.sync_person(@person_id, **PROVENANCE, employment_status: "left", title: "Lead")
      assert_equal "left", stream_events.first.data[:employment_status]
    end

    should "write a leaving once, however many syncs report it" do
      @handler.sync_person(@person_id, **PROVENANCE, employment_status: "employed", title: "Engineer")

      left = @handler.sync_person(@person_id, provider: "hibob", effective_on: "2026-11-02", employment_status: "left")
      again = @handler.sync_person(@person_id, provider: "hibob", effective_on: "2026-11-03", employment_status: "left")

      assert_equal [ 1, 0 ], [ left, again ]
      assert_equal "2026-11-02", stream_events.last.data[:effective_on]
    end

    should "write a return before the facts that changed with it" do
      @handler.sync_person(@person_id, **PROVENANCE, employment_status: "left", title: "Engineer")

      written = @handler.sync_person(@person_id, **PROVENANCE, employment_status: "employed", title: "Lead")

      assert_equal 2, written
      assert_equal [ OrgGraph::Events::PersonReturned, OrgGraph::Events::TitleChanged ], stream_events.drop(1).map(&:class)
    end

    should "refuse half a pair on the first sync as on every later one" do
      assert_raises(ArgumentError) do
        @handler.sync_person(@person_id, **PROVENANCE, employment_status: "employed", site: "Sydney")
      end
      assert_empty stream_events
    end
  end

  context "#apply_facts" do
    should "leave a person the Org Graph has not recorded alone" do
      assert_equal 0, @handler.apply_facts(@person_id, **PROVENANCE, title: "Engineer")
      assert_empty stream_events
    end

    should "write one event per differing fact in a single load, and none for the rest" do
      manager_id = SecureRandom.uuid_v7
      @handler.record_person(@person_id, **PROVENANCE, employment_status: "employed", title: "Engineer",
        level: "5", manager_id: manager_id, site: "Sydney", country: "Australia")

      written = @handler.apply_facts(@person_id, **PROVENANCE, title: "Senior Engineer", level: "5",
        manager_id: nil, site: "Sydney", country: "Australia")

      assert_equal 2, written
      assert_equal [ OrgGraph::Events::TitleChanged, OrgGraph::Events::ManagerChanged ], stream_events.drop(1).map(&:class)
    end

    should "not compare a fact it was not given" do
      @handler.record_person(@person_id, **PROVENANCE, employment_status: "employed", cost_centre: "CC-100")

      assert_equal 0, @handler.apply_facts(@person_id, **PROVENANCE, title: nil)
    end

    should "refuse a fact it does not name, or half a pair, recorded or not" do
      assert_raises(ArgumentError) { @handler.apply_facts(@person_id, **PROVENANCE, department: "Design") }

      @handler.record_person(@person_id, **PROVENANCE, employment_status: "employed")

      assert_raises(ArgumentError) { @handler.apply_facts(@person_id, **PROVENANCE, department: "Design") }
      assert_raises(ArgumentError) { @handler.apply_facts(@person_id, **PROVENANCE, site: "Sydney") }
    end
  end

  context "memberships" do
    setup do
      structure = OrgGraph::StructureCommandHandler.new
      level = SecureRandom.uuid_v7
      @squad = SecureRandom.uuid_v7
      @retired = SecureRandom.uuid_v7
      structure.define_taxonomy([ { level_id: level, name: "Squad" } ], effective_on: "2026-01-01")
      structure.create_unit(@squad, "Payments", level_id: level, effective_on: "2026-01-01")
      structure.create_unit(@retired, "Billing", level_id: level, effective_on: "2026-01-01")
      @handler.record_person(@person_id, **PROVENANCE, employment_status: "employed")
    end

    should "set and end a membership in the person's stream" do
      @handler.set_membership(@person_id, @squad, allocation: 0.5, role: "Engineer", **HELD_BY_ESPALIA)
      @handler.end_membership(@person_id, @squad, **HELD_BY_ESPALIA)

      assert_equal [ OrgGraph::Events::MembershipSet, OrgGraph::Events::MembershipEnded ], stream_events.drop(1).map(&:class)
    end

    should "move a membership to another unit as one event, keeping its terms" do
      @handler.set_membership(@person_id, @squad, allocation: 0.5, role: "Engineer", **HELD_BY_ESPALIA)
      @handler.move_membership(@person_id, @squad, @retired, effective_on: "2026-12-01", moved_by_id: @person_id)
      moved = stream_events.last

      assert_kind_of OrgGraph::Events::MembershipMoved, moved
      assert_equal [ @squad, @retired, 0.5, "Engineer", "espalia", "2026-12-01" ],
                   moved.data.values_at(:from_unit_id, :unit_id, :allocation, :role, :provider, :effective_on)
      assert_raises(RuntimeError, match: /Not a member/) { @handler.end_membership(@person_id, @squad, **HELD_BY_ESPALIA) }
    end

    should "end the old membership instead when the person is already in the destination" do
      @handler.set_membership(@person_id, @squad, **HELD_BY_ESPALIA)
      @handler.set_membership(@person_id, @retired, allocation: 0.3, **HELD_BY_ESPALIA)
      @handler.move_membership(@person_id, @squad, @retired, effective_on: "2026-12-01")

      assert_kind_of OrgGraph::Events::MembershipEnded, stream_events.last
      assert_equal @squad, stream_events.last.data[:unit_id]
    end

    should "refuse a move to a missing unit, the same unit, or before the membership began" do
      @handler.set_membership(@person_id, @squad, **HELD_BY_ESPALIA)

      assert_raises(RuntimeError, match: /Unit not found/) do
        @handler.move_membership(@person_id, @squad, SecureRandom.uuid_v7, effective_on: "2026-12-01")
      end
      assert_raises(RuntimeError, match: /unit it is in/) do
        @handler.move_membership(@person_id, @squad, @squad, effective_on: "2026-12-01")
      end
      assert_raises(RuntimeError, match: /before it begins/) do
        @handler.move_membership(@person_id, @squad, @retired, effective_on: "2026-10-01")
      end
    end

    should "refuse a unit that does not exist or is retired" do
      @handler.set_membership(@person_id, @retired, **HELD_BY_ESPALIA)
      OrgGraph::StructureCommandHandler.new.retire_unit(@retired, effective_on: "2026-06-30")

      assert_raises(RuntimeError, match: /Unit not found/) { @handler.set_membership(@person_id, SecureRandom.uuid_v7, **HELD_BY_ESPALIA) }
      assert_raises(RuntimeError, match: /Unit not found/) { @handler.set_membership(@person_id, "squad", **HELD_BY_ESPALIA) }
      assert_raises(RuntimeError, match: /retired/) { @handler.set_membership(@person_id, @retired, allocation: 0.5, **HELD_BY_ESPALIA) }
      assert_kind_of OrgGraph::Events::MembershipEnded, stream_events.last
    end

    should "not see another tenant's unit" do
      ActsAsTenant.with_tenant(create(:tenant)) do
        assert_raises(RuntimeError, match: /Unit not found/) { @handler.set_membership(@person_id, @squad, **HELD_BY_ESPALIA) }
      end
    end
  end

  context "refusing another provider's facts" do
    setup do
      @structure = OrgGraph::StructureCommandHandler.new
      @handler.record_person(@person_id, **PROVENANCE, employment_status: "employed", title: "Engineer")
    end

    should "refuse a fact from a provider that doesn't hold it, naming the one that does" do
      assert_raises(RuntimeError, match: "hibob supplies title; change it there") do
        @handler.change_title(@person_id, "Designer", **HELD_BY_ESPALIA)
      end
      assert_raises(RuntimeError, match: "hibob supplies site") do
        @handler.apply_facts(@person_id, **HELD_BY_ESPALIA, site: "Sydney", country: "Australia")
      end
    end

    should "take a fact from whoever holds it once the setting changes" do
      @structure.set_fact_provider("title", "espalia", effective_on: "2026-11-01")

      @handler.change_title(@person_id, "Designer", **HELD_BY_ESPALIA)
      assert_equal "Designer", stream_events.last.data[:title]
      assert_raises(RuntimeError, match: "espalia supplies title") { @handler.change_title(@person_id, "Lead", **PROVENANCE) }
    end

    should "refuse a sync whose status another provider holds, before touching the stream" do
      @structure.set_fact_provider("employment_status", "espalia", effective_on: "2026-11-01")
      written = stream_events.size

      assert_raises(RuntimeError, match: "espalia supplies employment_status") do
        @handler.sync_person(@person_id, **PROVENANCE, employment_status: "left")
      end
      assert_raises(RuntimeError, match: "espalia supplies employment_status") { @handler.leave(@person_id, **PROVENANCE) }
      assert_equal written, stream_events.size
    end

    should "take a membership only from its unit's provider" do
      level = SecureRandom.uuid_v7
      team = SecureRandom.uuid_v7
      @structure.define_taxonomy([ { level_id: level, name: "Team" } ], effective_on: "2026-01-01")
      @structure.set_level_provider(level, "hibob", effective_on: "2026-01-01")
      @structure.create_unit(team, "Payments", level_id: level, effective_on: "2026-01-01", provider: "hibob", external_ref: "t-1")

      assert_raises(RuntimeError, match: "hibob supplies this unit;") do
        @handler.set_membership(@person_id, team, **HELD_BY_ESPALIA)
      end
      @handler.set_membership(@person_id, team, **PROVENANCE)
      assert_raises(RuntimeError, match: "hibob supplies this unit;") do
        @handler.end_membership(@person_id, team, **HELD_BY_ESPALIA)
      end
      assert_nothing_raised { @handler.end_membership(@person_id, team, **PROVENANCE) }
    end

    should "move a membership only into a unit the membership's provider supplies" do
      squads, teams = SecureRandom.uuid_v7, SecureRandom.uuid_v7
      squad, team = SecureRandom.uuid_v7, SecureRandom.uuid_v7
      @structure.define_taxonomy([ { level_id: teams, name: "Team" }, { level_id: squads, name: "Squad" } ], effective_on: "2026-01-01")
      @structure.set_level_provider(teams, "hibob", effective_on: "2026-01-01")
      @structure.create_unit(squad, "Payments", level_id: squads, effective_on: "2026-01-01")
      @structure.create_unit(team, "Billing", level_id: teams, effective_on: "2026-01-01", provider: "hibob", external_ref: "t-1")
      @handler.set_membership(@person_id, squad, **HELD_BY_ESPALIA)

      assert_raises(RuntimeError, match: "hibob supplies this unit;") do
        @handler.move_membership(@person_id, squad, team, effective_on: "2026-12-01")
      end
    end
  end
end
