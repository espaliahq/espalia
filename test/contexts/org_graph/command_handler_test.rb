# frozen_string_literal: true

require "test_helper"

class OrgGraph::CommandHandlerTest < ActiveSupport::TestCase
  PROVENANCE = { provider: "hibob", effective_on: "2026-11-01" }.freeze

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @handler = OrgGraph::CommandHandler.new
    @person_id = SecureRandom.uuid_v7
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

    should "record the start date, and a leaver's leaving date, with the person" do
      @handler.sync_person(@person_id, **PROVENANCE, employment_status: "employed", started_on: "2023-01-15", left_on: "2026-12-01")
      other = SecureRandom.uuid_v7
      @handler.sync_person(other, **PROVENANCE, employment_status: "left", started_on: "2023-01-15", left_on: "2026-10-31")

      assert_equal [ "2023-01-15", nil ], stream_events.first.data.values_at(:started_on, :left_on)
      leaver = Rails.configuration.event_store.read.stream(EventStreamNaming.person_stream(other)).first
      assert_equal "2026-10-31", leaver.data[:left_on]
    end

    should "supply a start date the stream lacks, once" do
      @handler.sync_person(@person_id, **PROVENANCE, employment_status: "employed")

      assert_equal 1, @handler.sync_person(@person_id, **PROVENANCE, employment_status: "employed", started_on: "2023-01-15")
      assert_equal 0, @handler.sync_person(@person_id, **PROVENANCE, employment_status: "employed", started_on: "2023-01-15")
      assert_kind_of OrgGraph::Events::StartDateChanged, stream_events.last
    end

    should "keep a future starter pending, then join them on their start date" do
      @handler.sync_person(@person_id, **PROVENANCE, employment_status: "pending", started_on: "2026-11-20")
      @handler.sync_person(@person_id, **PROVENANCE, employment_status: "pending", started_on: "2026-11-20")
      @handler.sync_person(@person_id, provider: "hibob", effective_on: "2026-11-21", employment_status: "employed", started_on: "2026-11-20")

      assert_equal [ OrgGraph::Events::PersonRecorded, OrgGraph::Events::PersonJoined ], stream_events.map(&:class)
      assert_equal "2026-11-20", stream_events.last.data[:effective_on]
    end

    should "date a leaving by the termination date the provider holds" do
      @handler.sync_person(@person_id, **PROVENANCE, employment_status: "employed")
      @handler.sync_person(@person_id, **PROVENANCE, employment_status: "left", left_on: "2026-10-31")

      assert_equal [ OrgGraph::Events::PersonLeft, "2026-10-31" ], [ stream_events.last.class, stream_events.last.data[:effective_on] ]
    end

    should "drop a leaving date before the start date, so the person is still recorded and left" do
      @handler.sync_person(@person_id, **PROVENANCE, employment_status: "left", started_on: "2026-12-01", left_on: "2026-11-15")
      other = SecureRandom.uuid_v7
      @handler.sync_person(other, **PROVENANCE, employment_status: "employed", started_on: "2023-01-15")
      @handler.sync_person(other, **PROVENANCE, employment_status: "left", started_on: "2023-01-15", left_on: "2022-12-31")

      assert_equal [ "left", nil ], stream_events.first.data.values_at(:employment_status, :left_on)
      leaving = Rails.configuration.event_store.read.stream(EventStreamNaming.person_stream(other)).last
      assert_equal [ OrgGraph::Events::PersonLeft, "2026-11-01" ], [ leaving.class, leaving.data[:effective_on] ]
    end

    should "not compare a leaver's facts or start date while their rehire is pending" do
      @handler.sync_person(@person_id, **PROVENANCE, employment_status: "employed", title: "Engineer")
      @handler.sync_person(@person_id, **PROVENANCE, employment_status: "left")

      assert_equal 0, @handler.sync_person(@person_id, **PROVENANCE, employment_status: "pending",
        started_on: "2026-12-01", title: "Lead")
    end

    should "check a leaving against the start date the same sync corrects" do
      @handler.sync_person(@person_id, **PROVENANCE, employment_status: "employed", started_on: "2026-11-10")

      @handler.sync_person(@person_id, **PROVENANCE, employment_status: "left", started_on: "2026-11-01", left_on: "2026-11-05")

      assert_equal [ [ OrgGraph::Events::StartDateChanged, "2026-11-01" ], [ OrgGraph::Events::PersonLeft, "2026-11-05" ] ],
        stream_events.drop(1).map { |e| [ e.class, e.data[:effective_on] ] }
    end

    should "keep a hire pending until their recorded start when the provider sends none, then join them on it" do
      @handler.sync_person(@person_id, **PROVENANCE, employment_status: "pending", started_on: "2026-11-20")

      assert_equal 0, @handler.sync_person(@person_id, provider: "hibob", effective_on: "2026-11-05", employment_status: "employed")
      @handler.sync_person(@person_id, provider: "hibob", effective_on: "2026-11-21", employment_status: "employed")
      assert_equal [ OrgGraph::Events::PersonJoined, "2026-11-20" ], [ stream_events.last.class, stream_events.last.data[:effective_on] ]
    end

    should "refuse half a pair on the first sync as on every later one" do
      assert_raises(ArgumentError) do
        @handler.sync_person(@person_id, **PROVENANCE, employment_status: "employed", site: "Sydney")
      end
      assert_empty stream_events
    end
  end

  context "#record_absence" do
    should "leave someone the provider stopped returning, once" do
      @handler.sync_person(@person_id, **PROVENANCE, employment_status: "employed")

      first = @handler.record_absence(@person_id, provider: "hibob", effective_on: "2026-11-02")
      again = @handler.record_absence(@person_id, provider: "hibob", effective_on: "2026-11-03")

      assert_equal [ 1, 0 ], [ first, again ]
      assert_instance_of OrgGraph::Events::PersonLeft, stream_events.last
      assert_equal "2026-11-02", stream_events.last.data[:effective_on]
    end

    should "leave a future starter who disappears before their start date" do
      @handler.sync_person(@person_id, **PROVENANCE, employment_status: "pending", started_on: "2026-12-01")

      assert_equal 1, @handler.record_absence(@person_id, provider: "hibob", effective_on: "2026-11-02")
      assert_instance_of OrgGraph::Events::PersonLeft, stream_events.last
    end

    should "write nothing for someone the provider already reported as left" do
      @handler.sync_person(@person_id, **PROVENANCE, employment_status: "employed")
      @handler.sync_person(@person_id, provider: "hibob", effective_on: "2026-11-02", employment_status: "left")

      assert_equal 0, @handler.record_absence(@person_id, provider: "hibob", effective_on: "2026-11-05")
      assert_equal "2026-11-02", stream_events.last.data[:effective_on]
    end

    should "write nothing for someone the Org Graph never recorded" do
      assert_equal 0, @handler.record_absence(@person_id, provider: "hibob", effective_on: "2026-11-02")
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
      @handler.set_membership(@person_id, @squad, allocation: 0.5, role: "Engineer", **PROVENANCE)
      @handler.end_membership(@person_id, @squad, **PROVENANCE)

      assert_equal [ OrgGraph::Events::MembershipSet, OrgGraph::Events::MembershipEnded ], stream_events.drop(1).map(&:class)
    end

    should "move a membership to another unit as one event, keeping its terms" do
      @handler.set_membership(@person_id, @squad, allocation: 0.5, role: "Engineer", **PROVENANCE)
      @handler.move_membership(@person_id, @squad, @retired, effective_on: "2026-12-01", moved_by_id: @person_id)
      moved = stream_events.last

      assert_kind_of OrgGraph::Events::MembershipMoved, moved
      assert_equal [ @squad, @retired, 0.5, "Engineer", "hibob", "2026-12-01" ],
                   moved.data.values_at(:from_unit_id, :unit_id, :allocation, :role, :provider, :effective_on)
      assert_raises(RuntimeError, match: /Not a member/) { @handler.end_membership(@person_id, @squad, **PROVENANCE) }
    end

    should "end the old membership instead when the person is already in the destination" do
      @handler.set_membership(@person_id, @squad, **PROVENANCE)
      @handler.set_membership(@person_id, @retired, allocation: 0.3, **PROVENANCE)
      @handler.move_membership(@person_id, @squad, @retired, effective_on: "2026-12-01")

      assert_kind_of OrgGraph::Events::MembershipEnded, stream_events.last
      assert_equal @squad, stream_events.last.data[:unit_id]
    end

    should "refuse a move to a missing unit, the same unit, or before the membership began" do
      @handler.set_membership(@person_id, @squad, **PROVENANCE)

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
      @handler.set_membership(@person_id, @retired, **PROVENANCE)
      OrgGraph::StructureCommandHandler.new.retire_unit(@retired, effective_on: "2026-06-30")

      assert_raises(RuntimeError, match: /Unit not found/) { @handler.set_membership(@person_id, SecureRandom.uuid_v7, **PROVENANCE) }
      assert_raises(RuntimeError, match: /Unit not found/) { @handler.set_membership(@person_id, "squad", **PROVENANCE) }
      assert_raises(RuntimeError, match: /retired/) { @handler.set_membership(@person_id, @retired, allocation: 0.5, **PROVENANCE) }
      assert_kind_of OrgGraph::Events::MembershipEnded, stream_events.last
    end

    should "not see another tenant's unit" do
      ActsAsTenant.with_tenant(create(:tenant)) do
        assert_raises(RuntimeError, match: /Unit not found/) { @handler.set_membership(@person_id, @squad, **PROVENANCE) }
      end
    end
  end
end
