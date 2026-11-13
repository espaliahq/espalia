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
end
