# frozen_string_literal: true

require "test_helper"

class OrgGraph::ForgetDueLeaversJobTest < ActiveJob::TestCase
  PROVENANCE = { provider: "espalia", effective_on: "2020-01-01" }.freeze

  def tenant_with_leaver(scheduled:)
    tenant = create(:tenant, org_graph_config: { scheduled_forgetting: scheduled })
    leaver = ActsAsTenant.with_tenant(tenant) do
      person = create(:person, tenant:)
      handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      handler.sync_person(person.id, **PROVENANCE, employment_status: "employed")
      handler.sync_person(person.id, **PROVENANCE, employment_status: "left", left_on: "2010-01-01")
      person
    end
    [ tenant, leaver ]
  end

  should "forget due leavers only where the schedule is on, as the system" do
    on, = tenant_with_leaver(scheduled: true)
    _, spared = tenant_with_leaver(scheduled: false)
    forgotten = ActsAsTenant.with_tenant(on) { Person.first }

    OrgGraph::ForgetDueLeaversJob.perform_now

    assert forgotten.reload.forgotten?
    assert_not spared.reload.forgotten?
    stream = ActsAsTenant.with_tenant(on) { EventStreamNaming.person_stream(forgotten.id) }
    event = Rails.configuration.event_store.read.stream(stream).last
    assert_equal "system", event.metadata[:acting_via]
  end

  should "keep going past a tenant whose run fails" do
    failing, kept = tenant_with_leaver(scheduled: true)
    _, forgotten = tenant_with_leaver(scheduled: true)
    real = OrgGraph::Forgetting.method(:new)
    fake = ->(tenant, **) { tenant == failing ? raise("unreachable") : real.call(tenant) }

    OrgGraph::Forgetting.stub(:new, fake) { OrgGraph::ForgetDueLeaversJob.perform_now }

    assert_not kept.reload.forgotten?
    assert forgotten.reload.forgotten?
  end

  should "fail loudly, forgetting nobody, without the key" do
    _, leaver = tenant_with_leaver(scheduled: true)

    OrgGraph::Forgetting.stub(:key, nil) do
      assert_raises(OrgGraph::Forgetting::KeyMissing) { OrgGraph::ForgetDueLeaversJob.perform_now }
    end
    assert_not leaver.reload.forgotten?
  end
end
