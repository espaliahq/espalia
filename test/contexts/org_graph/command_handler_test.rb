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
end
