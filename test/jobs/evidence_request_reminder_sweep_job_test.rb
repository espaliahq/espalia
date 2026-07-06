# frozen_string_literal: true

require "test_helper"

# The reminder sweep end to end: eligibility query → due_reminder_kind →
# remind_evidence_request → EvidenceRequests projection stamps. Fine-grained
# timing rules are unit-tested on EvidenceRequest#due_reminder_kind; here we
# pin the wiring and the once-only behaviour of a re-run.
class EvidenceRequestReminderSweepJobTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @handler = PersonDevelopment::CommandHandler.new

    @assessee = create(:person, tenant: @tenant)
    @requestee = create(:person, tenant: @tenant)
    @framework_id = SecureRandom.uuid_v7
    @handler.assign_to_framework(@assessee.id, @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def request_at!(time, due_at: nil)
    id = SecureRandom.uuid_v7
    travel_to(time) do
      @handler.request_evidence(@assessee.id, @framework_id, id,
        requested_by_id: @assessee.id, requestee_person_id: @requestee.id,
        capability_stable_id: SecureRandom.uuid_v7, level_ordinal: 2, due_at: due_at&.iso8601)
    end
    id
  end

  def sweep!
    # The sweep resolves tenants itself; run it outside any ambient scope the
    # way the recurring scheduler would.
    ActsAsTenant.without_tenant { EvidenceRequestReminderSweepJob.perform_now }
  end

  should "send a no_response reminder for a week-old unanswered request" do
    id = request_at!(8.days.ago)
    sweep!

    req = EvidenceRequest.find(id)
    assert_not_nil req.no_response_reminded_at
    assert_nil req.due_soon_reminded_at
  end

  should "send a due_soon reminder ahead of the due date" do
    id = request_at!(3.days.ago, due_at: 1.day.from_now)
    sweep!

    req = EvidenceRequest.find(id)
    assert_not_nil req.due_soon_reminded_at
    assert_nil req.no_response_reminded_at
  end

  should "leave fresh and resolved requests alone" do
    fresh = request_at!(2.days.ago)
    declined = request_at!(9.days.ago)
    @handler.decline_evidence_request(@assessee.id, @framework_id, declined, declined_by_id: @requestee.id)

    sweep!

    assert_nil EvidenceRequest.find(fresh).last_reminded_at
    assert_nil EvidenceRequest.find(declined).last_reminded_at
  end

  should "not remind again on a re-run" do
    id = request_at!(8.days.ago)
    sweep!
    first_stamp = EvidenceRequest.find(id).no_response_reminded_at

    sweep!

    req = EvidenceRequest.find(id)
    assert_equal first_stamp, req.no_response_reminded_at
    assert_nil req.due_soon_reminded_at
  end

  should "stamp system provenance on the reminder event" do
    request_at!(8.days.ago)
    sweep!

    event = Rails.configuration.event_store.read
      .of_type([ PersonDevelopment::Events::EvidenceRequestReminderSent ]).to_a.last
    assert_not_nil event
    assert_equal "system", event.metadata[:acting_via]
    assert_not_nil event.metadata[:correlation_id]
    assert_equal @tenant.id, event.metadata[:tenant_id]
  end
end
