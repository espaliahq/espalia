# frozen_string_literal: true

require "test_helper"
require "rake"

class OrgGraphClaimHrisFactsTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    Rake::Task["org_graph:claim_hris_facts"].reenable
    @connected = create(:tenant, :with_hibob_config)
    @unconnected = create(:tenant)
  end

  def run_task
    out, = capture_io { Rake::Task["org_graph:claim_hris_facts"].invoke }
    Rake::Task["org_graph:claim_hris_facts"].reenable
    out
  end

  def provider_for(tenant, fact)
    ActsAsTenant.with_tenant(tenant) { OrgFactProvider.provider_for(fact) }
  end

  should "hand each configured HRIS its default facts, and leave other tenants alone" do
    out = run_task

    assert_match "[#{@connected.id}] claimed #{OrgGraph::StructureAggregate::HRIS_FACTS.join(", ")}", out
    assert_equal "hibob", provider_for(@connected, "manager")
    assert_equal "espalia", provider_for(@unconnected, "manager")
  end

  should "write nothing when run again, and record the run as the system's" do
    run_task
    events = Rails.configuration.event_store.read.of_type(OrgGraph::Events::FactProviderSet).to_a

    assert_match "nothing new to claim", run_task
    assert_equal events.size, Rails.configuration.event_store.read.of_type(OrgGraph::Events::FactProviderSet).count
    assert(events.all? { |event| event.metadata[:acting_via] == "system" })
  end

  should "report a tenant that fails and still claim for the others" do
    other = create(:tenant, :with_hibob_config)
    real = Tenant.instance_method(:claim_hris_facts!)
    connected_id = @connected.id
    Tenant.define_method(:claim_hris_facts!) { id == connected_id ? raise("stream unavailable") : real.bind_call(self) }

    out = run_task

    assert_match "[#{@connected.id}] failed: RuntimeError: stream unavailable", out
    assert_equal "hibob", provider_for(other, "manager")
  ensure
    Tenant.define_method(:claim_hris_facts!, real)
  end
end
