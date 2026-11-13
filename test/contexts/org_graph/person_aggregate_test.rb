# frozen_string_literal: true

require "test_helper"

class OrgGraph::PersonAggregateTest < ActiveSupport::TestCase
  PROVENANCE = { provider: "hibob", effective_on: "2026-11-01" }.freeze

  setup do
    @aggregate = OrgGraph::PersonAggregate.new
    @person_id = SecureRandom.uuid_v7
    @manager_id = SecureRandom.uuid_v7
  end

  def record(employment_status: "employed", **facts)
    @aggregate.record(@person_id, **PROVENANCE, employment_status: employment_status, **facts)
  end

  def events
    @aggregate.unpublished_events.to_a
  end

  def every_kind_of_event
    record(employment_status: "pending", title: "Engineer", manager_id: @manager_id, fte: 1)
    @aggregate.join(**PROVENANCE)
    @aggregate.change_title("Senior Engineer", **PROVENANCE)
    @aggregate.change_level("L4", **PROVENANCE)
    @aggregate.change_manager(SecureRandom.uuid_v7, **PROVENANCE)
    @aggregate.change_cost_centre("CC-100 Platform", **PROVENANCE)
    @aggregate.change_site(site: "Melbourne", country: "Australia", **PROVENANCE)
    @aggregate.change_employment(fte: 0.6, employment_type: "Part time", **PROVENANCE)
    @aggregate.leave(**PROVENANCE)
    @aggregate.return_to_work(**PROVENANCE)
    events
  end

  context "every event" do
    should "carry the person, the provider and the effective date" do
      every_kind_of_event.each do |event|
        assert_equal @person_id, event.data[:person_id], event.class.name
        assert_equal "hibob", event.data[:provider], event.class.name
        assert_equal "2026-11-01", event.data[:effective_on], event.class.name
      end
    end

    should "hold only named operational facts, never an identifier" do
      allowed = %i[person_id provider effective_on employment_status started_on left_on] + %i[
        title level manager_id cost_centre site country fte employment_type
      ]

      kinds = every_kind_of_event.each { |event| assert_empty event.data.keys - allowed, event.class.name }.map(&:class)
      assert_equal 10, kinds.uniq.size
    end
  end

  context "#record" do
    should "record the facts as they stood" do
      record(started_on: Date.new(2024, 3, 4), title: " Engineer ", level: "L3", manager_id: @manager_id,
        cost_centre: "CC-100", site: "Sydney", country: "Australia", fte: "0.8", employment_type: "Permanent")

      assert_equal [ OrgGraph::Events::PersonRecorded ], events.map(&:class)
      data = events.first.data
      assert_equal "employed", data[:employment_status]
      assert_equal "2024-03-04", data[:started_on]
      assert_nil data[:left_on]
      assert_equal "Engineer", data[:title]
      assert_equal @manager_id, data[:manager_id]
      assert_in_delta 0.8, data[:fte]
    end

    should "refuse a second record" do
      record
      assert_raises(RuntimeError, match: /already recorded/) { record }
    end

    should "refuse an unknown employment status" do
      assert_raises(RuntimeError, match: /employment status/) { record(employment_status: "contractor") }
    end

    should "refuse an unknown provider" do
      assert_raises(RuntimeError, match: /Unknown provider/) do
        @aggregate.record(@person_id, provider: "workday", effective_on: "2026-11-01", employment_status: "employed")
      end
    end

    should "refuse a missing or malformed effective date" do
      assert_raises(RuntimeError, match: /Effective date/) do
        @aggregate.record(@person_id, provider: "hibob", effective_on: nil, employment_status: "employed")
      end
      assert_raises(RuntimeError, match: /Invalid effective_on/) do
        @aggregate.record(@person_id, provider: "hibob", effective_on: "1 Nov", employment_status: "employed")
      end
    end

    should "store a date-time as its date" do
      [ Time.zone.parse("2026-11-01 23:30"), DateTime.new(2026, 11, 1, 10) ].each do |moment|
        aggregate = OrgGraph::PersonAggregate.new
        aggregate.record(@person_id, provider: "hibob", effective_on: moment, employment_status: "employed")
        assert_equal "2026-11-01", aggregate.unpublished_events.first.data[:effective_on]
      end
    end

    should "refuse a leaving date before the start date" do
      assert_raises(RuntimeError, match: /leave before they start/) do
        record(employment_status: "left", started_on: "2026-01-10", left_on: "2025-12-01")
      end
    end

    should "refuse a person as their own manager" do
      assert_raises(RuntimeError, match: /manage themselves/) { record(manager_id: @person_id) }
    end

    should "refuse an FTE outside (0, 1]" do
      [ 0, 1.2, "lots" ].each do |fte|
        assert_raises(RuntimeError, match: /FTE/) { OrgGraph::PersonAggregate.new.record(@person_id, **PROVENANCE, employment_status: "employed", fte: fte) }
      end
    end

    should "refuse a field it does not name" do
      assert_raises(ArgumentError) { record(email: "someone@example.com") }
    end
  end

  context "a change" do
    should "refuse a person never recorded" do
      assert_raises(RuntimeError, match: /not recorded/) { @aggregate.change_title("Engineer", **PROVENANCE) }
    end

    should "write nothing when the fact already holds" do
      record(title: "Engineer", site: "Sydney", country: "Australia")
      @aggregate.change_title(" Engineer ", **PROVENANCE)
      @aggregate.change_site(site: "Sydney", country: "Australia", **PROVENANCE)
      @aggregate.change_manager(nil, **PROVENANCE)

      assert_equal [ OrgGraph::Events::PersonRecorded ], events.map(&:class)
    end

    should "write the new value when it differs" do
      record(manager_id: @manager_id)
      @aggregate.change_manager(nil, provider: "espalia", effective_on: "2026-12-01")

      event = events.last
      assert_kind_of OrgGraph::Events::ManagerChanged, event
      assert_nil event.data[:manager_id]
      assert_equal "espalia", event.data[:provider]
      assert_equal "2026-12-01", event.data[:effective_on]
    end

    should "compare against the latest change, not the first record" do
      record(title: "Engineer")
      @aggregate.change_title("Senior Engineer", **PROVENANCE)
      @aggregate.change_title("Senior Engineer", **PROVENANCE)
      @aggregate.change_title("Engineer", **PROVENANCE)

      assert_equal [ "Senior Engineer", "Engineer" ], events.drop(1).map { |e| e.data[:title] }
    end

    should "write the same value again when another provider supplies it" do
      record(title: "Lead")
      @aggregate.change_title("Lead", provider: "espalia", effective_on: "2026-11-02")

      assert_equal "espalia", events.last.data[:provider]
      assert_kind_of OrgGraph::Events::TitleChanged, events.last
    end

    should "treat a blank FTE as none" do
      record(fte: 1)
      @aggregate.change_employment(fte: "", employment_type: nil, **PROVENANCE)

      assert_nil events.last.data[:fte]
    end

    should "validate its provenance even when nothing changed" do
      record(title: "Engineer")
      assert_raises(RuntimeError, match: /Unknown provider/) do
        @aggregate.change_title("Engineer", provider: "workday", effective_on: "2026-11-01")
      end
    end
  end

  context "employment status" do
    should "move a pending person to employed on joining" do
      record(employment_status: "pending")
      @aggregate.join(**PROVENANCE)
      @aggregate.join(**PROVENANCE)

      assert_equal [ OrgGraph::Events::PersonRecorded, OrgGraph::Events::PersonJoined ], events.map(&:class)
    end

    should "let an employed person leave once and return" do
      record
      @aggregate.leave(**PROVENANCE)
      @aggregate.leave(**PROVENANCE)
      @aggregate.return_to_work(**PROVENANCE)

      assert_equal [ OrgGraph::Events::PersonRecorded, OrgGraph::Events::PersonLeft, OrgGraph::Events::PersonReturned ],
        events.map(&:class)
    end

    should "let a hire who never started leave" do
      record(employment_status: "pending")
      @aggregate.leave(**PROVENANCE)

      assert_kind_of OrgGraph::Events::PersonLeft, events.last
    end

    should "write a corrected date as a new event, and a repeated one as nothing" do
      record
      @aggregate.leave(provider: "hibob", effective_on: "2026-11-30")
      @aggregate.leave(provider: "hibob", effective_on: "2026-11-30")
      @aggregate.leave(provider: "hibob", effective_on: "2026-12-15")

      assert_equal [ "2026-11-30", "2026-12-15" ], events.drop(1).map { |e| e.data[:effective_on] }
    end

    should "refuse an employed person leaving before their start date" do
      record(started_on: "2026-11-10")
      assert_raises(RuntimeError, match: /leave before they start/) do
        @aggregate.leave(provider: "hibob", effective_on: "2026-11-01")
      end

      joined = OrgGraph::PersonAggregate.new
      joined.record(@person_id, **PROVENANCE, employment_status: "pending", started_on: "2026-11-01")
      joined.join(provider: "hibob", effective_on: "2026-11-20")
      assert_raises(RuntimeError, match: /leave before they start/) do
        joined.leave(provider: "hibob", effective_on: "2026-11-15")
      end
    end

    should "write a status repeated by another provider as a handover" do
      record
      @aggregate.leave(provider: "hibob", effective_on: "2026-11-30")
      @aggregate.leave(provider: "espalia", effective_on: "2026-11-30")
      @aggregate.leave(provider: "espalia", effective_on: "2026-11-30")

      assert_equal [ "hibob", "espalia" ], events.drop(1).map { |e| e.data[:provider] }
    end

    should "refuse a corrected leaving date before the start date, unless they never started" do
      record(started_on: "2026-11-10")
      @aggregate.leave(provider: "hibob", effective_on: "2026-11-30")
      assert_raises(RuntimeError, match: /leave before they start/) do
        @aggregate.leave(provider: "hibob", effective_on: "2026-11-01")
      end

      dropout = OrgGraph::PersonAggregate.new
      dropout.record(@person_id, **PROVENANCE, employment_status: "pending", started_on: "2026-11-10")
      dropout.leave(provider: "hibob", effective_on: "2026-11-05")
      dropout.leave(provider: "hibob", effective_on: "2026-11-01")
      assert_equal [ "2026-11-05", "2026-11-01" ], dropout.unpublished_events.drop(1).map { |e| e.data[:effective_on] }
    end

    should "write nothing when joining someone recorded as employed" do
      record
      @aggregate.join(**PROVENANCE)

      assert_equal [ OrgGraph::Events::PersonRecorded ], events.map(&:class)
    end

    should "refuse a move the status does not allow" do
      record(employment_status: "pending")
      assert_raises(RuntimeError, match: /from pending to employed/) { @aggregate.return_to_work(**PROVENANCE) }

      left = OrgGraph::PersonAggregate.new
      left.record(@person_id, **PROVENANCE, employment_status: "left")
      assert_raises(RuntimeError, match: /from left to employed/) { left.join(**PROVENANCE) }
    end
  end

  context "#match_status" do
    should "write only the move a reported status needs, never a new date for the same one" do
      record(employment_status: "pending")
      @aggregate.match_status("employed", provider: "hibob", effective_on: "2026-11-02")
      @aggregate.match_status("left", provider: "hibob", effective_on: "2026-11-03")
      @aggregate.match_status("left", provider: "hibob", effective_on: "2026-11-04")
      @aggregate.match_status("employed", provider: "hibob", effective_on: "2026-11-05")

      assert_equal [
        [ OrgGraph::Events::PersonJoined, "2026-11-02" ],
        [ OrgGraph::Events::PersonLeft, "2026-11-03" ],
        [ OrgGraph::Events::PersonReturned, "2026-11-05" ]
      ], events.drop(1).map { |e| [ e.class, e.data[:effective_on] ] }
    end

    should "refuse a status it does not know" do
      record
      assert_raises(RuntimeError) { @aggregate.match_status("retired", **PROVENANCE) }
    end
  end

  context "memberships" do
    setup do
      @squad = SecureRandom.uuid_v7
      @guild = SecureRandom.uuid_v7
      record
    end

    should "let a person be in several units, each with its own allocation and role" do
      @aggregate.set_membership(@squad, allocation: "0.6", role: " Tech lead ", **PROVENANCE)
      @aggregate.set_membership(@guild.upcase, allocation: 0.4, **PROVENANCE)

      squad, guild = events.drop(1)
      assert_equal [ OrgGraph::Events::MembershipSet ] * 2, [ squad.class, guild.class ]
      assert_equal({ person_id: @person_id, unit_id: @squad, allocation: 0.6, role: "Tech lead", provider: "hibob",
                     effective_on: "2026-11-01", set_by_id: nil, plan_change_id: nil }, squad.data.symbolize_keys)
      assert_equal @guild, guild.data[:unit_id]
      assert_nil guild.data[:role]
    end

    should "carry the actor and the plan change" do
      actor = SecureRandom.uuid_v7
      @aggregate.set_membership(@squad, provider: "espalia", effective_on: "2026-11-02", set_by_id: actor, plan_change_id: "chg-1")
      @aggregate.end_membership(@squad, provider: "espalia", effective_on: "2026-12-31", ended_by_id: actor)

      set, ended = events.drop(1)
      assert_equal [ "espalia", "2026-11-02", actor, "chg-1" ], set.data.values_at(:provider, :effective_on, :set_by_id, :plan_change_id)
      assert_equal [ @squad, "2026-12-31", actor ], ended.data.values_at(:unit_id, :effective_on, :ended_by_id)
    end

    should "write nothing for the same terms from the same provider, whatever the date" do
      @aggregate.set_membership(@squad, allocation: 1, role: "Engineer", **PROVENANCE)
      @aggregate.set_membership(@squad, allocation: 1.0, role: "Engineer", provider: "hibob", effective_on: "2026-12-01")

      assert_equal 1, events.count { |event| event.is_a?(OrgGraph::Events::MembershipSet) }
    end

    should "write new terms, or a handover to another provider" do
      @aggregate.set_membership(@squad, allocation: 1, **PROVENANCE)
      @aggregate.set_membership(@squad, allocation: 0.5, **PROVENANCE)
      @aggregate.set_membership(@squad, allocation: 0.5, provider: "espalia", effective_on: "2026-11-01")

      assert_equal [ 1.0, 0.5, 0.5 ], events.drop(1).map { |event| event.data[:allocation] }
    end

    should "end one membership and leave the others" do
      @aggregate.set_membership(@squad, **PROVENANCE)
      @aggregate.set_membership(@guild, **PROVENANCE)
      @aggregate.end_membership(@squad, **PROVENANCE)

      assert_raises(RuntimeError, match: /Not a member/) { @aggregate.end_membership(@squad, **PROVENANCE) }
      assert_nothing_raised { @aggregate.end_membership(@guild, **PROVENANCE) }
    end

    should "let a person rejoin a unit they left" do
      @aggregate.set_membership(@squad, **PROVENANCE)
      @aggregate.end_membership(@squad, **PROVENANCE)
      @aggregate.set_membership(@squad, **PROVENANCE)

      assert_equal [ OrgGraph::Events::MembershipSet, OrgGraph::Events::MembershipEnded, OrgGraph::Events::MembershipSet ],
        events.drop(1).map(&:class)
    end

    should "refuse to end a membership before its last change, by date" do
      @aggregate.set_membership(@squad, allocation: 1, provider: "hibob", effective_on: "2026-03-01")
      @aggregate.set_membership(@squad, allocation: 0.5, provider: "hibob", effective_on: "2026-06-01")

      assert_raises(RuntimeError, match: /end before its last change on 2026-06-01/) do
        @aggregate.end_membership(@squad, provider: "hibob", effective_on: "2026-04-01")
      end
      assert_nothing_raised { @aggregate.end_membership(@squad, provider: "hibob", effective_on: "2026-06-01") }
    end

    should "refuse an allocation outside (0, 1], a bad unit id or provider, and a person who has left" do
      assert_raises(RuntimeError, match: /at most 1/) { @aggregate.set_membership(@squad, allocation: 1.5, **PROVENANCE) }
      assert_raises(RuntimeError, match: /at most 1/) { @aggregate.set_membership(@squad, allocation: 0, **PROVENANCE) }
      assert_raises(RuntimeError, match: /Invalid Allocation/) { @aggregate.set_membership(@squad, allocation: "half", **PROVENANCE) }
      assert_raises(RuntimeError, match: /must be a UUID/) { @aggregate.set_membership("squad", **PROVENANCE) }
      assert_raises(RuntimeError, match: /Unknown provider/) { @aggregate.set_membership(@squad, provider: "x", effective_on: "2026-11-01") }

      @aggregate.leave(**PROVENANCE)
      assert_raises(RuntimeError, match: /has left/) { @aggregate.set_membership(@squad, **PROVENANCE) }
    end

    should "accept a backdated change, still ending no earlier than the latest one" do
      @aggregate.set_membership(@squad, allocation: 1, provider: "hibob", effective_on: "2026-03-01")
      @aggregate.set_membership(@squad, allocation: 0.5, provider: "hibob", effective_on: "2026-02-01")

      assert_equal "2026-02-01", events.last.data[:effective_on]
      assert_raises(RuntimeError, match: /last change on 2026-03-01/) do
        @aggregate.end_membership(@squad, provider: "hibob", effective_on: "2026-02-15")
      end
      assert_nothing_raised { @aggregate.end_membership(@squad, provider: "hibob", effective_on: "2026-03-01") }
    end

    should "refuse to restart a membership before the last one ended, and allow it from that day" do
      @aggregate.set_membership(@squad, provider: "hibob", effective_on: "2026-03-01")
      @aggregate.end_membership(@squad, provider: "hibob", effective_on: "2026-06-30")

      assert_raises(RuntimeError, match: /restart before the last one ended on 2026-06-30/) do
        @aggregate.set_membership(@squad, provider: "hibob", effective_on: "2026-05-01")
      end
      assert_nothing_raised { @aggregate.set_membership(@squad, provider: "hibob", effective_on: "2026-06-30") }
      assert_nothing_raised { @aggregate.set_membership(@guild, provider: "hibob", effective_on: "2026-05-01") }
    end

    should "replay the dates from the stream, so a reloaded person keeps the same rules" do
      @aggregate.set_membership(@squad, provider: "hibob", effective_on: "2026-03-01")
      @aggregate.end_membership(@squad, provider: "hibob", effective_on: "2026-06-30")
      @aggregate.set_membership(@guild, allocation: 1, provider: "hibob", effective_on: "2026-07-01")

      reloaded = OrgGraph::PersonAggregate.new
      events.each { |event| reloaded.apply(event) }

      assert_raises(RuntimeError, match: /restart/) { reloaded.set_membership(@squad, provider: "hibob", effective_on: "2026-06-01") }
      assert_raises(RuntimeError, match: /last change/) { reloaded.end_membership(@guild, provider: "hibob", effective_on: "2026-06-01") }
    end

    should "place a hire before they start, and refuse a person not yet recorded" do
      pending = OrgGraph::PersonAggregate.new
      assert_raises(RuntimeError, match: /not recorded/) { pending.set_membership(@squad, **PROVENANCE) }

      pending.record(@person_id, **PROVENANCE, employment_status: "pending")
      assert_nothing_raised { pending.set_membership(@squad, **PROVENANCE) }
    end
  end
end
