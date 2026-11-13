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
end
