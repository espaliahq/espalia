# frozen_string_literal: true

require "test_helper"
require "rake"

class OrgGraphTaxonomyCheckTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @tenant = create(:tenant)
    @handler = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    @division, @department, @team = Array.new(3) { SecureRandom.uuid_v7 }
    @ops, @payments = SecureRandom.uuid_v7, SecureRandom.uuid_v7
    as_tenant do
      @handler.define_taxonomy([ { level_id: @division, name: "Division" }, { level_id: @department, name: "Department" },
                                 { level_id: @team, name: "Team" } ], effective_on: "2026-01-01")
      @handler.create_unit(@ops, "Ops", level_id: @division, effective_on: "2026-01-01")
      @handler.create_unit(@payments, "Payments", level_id: @team, parent_id: @ops, effective_on: "2026-01-01")
    end
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def run_task
    out, = capture_io { Rake::Task["org_graph:taxonomy:check"].invoke }
    out
  ensure
    Rake::Task["org_graph:taxonomy:check"].reenable
  end

  should "pass a structure every unit of which sits where its kind may" do
    assert_match "[#{@tenant.id}] 0 misplaced units, 0 changes to the kinds dated out of order", run_task
  end

  should "fail on a unit of an HRIS level beneath anything but the HRIS level directly above it" do
    as_tenant do
      { @division => { @ops => "ops" }, @department => {} }.each do |level_id, matches|
        @handler.hand_over_level(level_id, "hibob", field: "work.#{level_id.first(4)}", matches:, effective_on: "2026-02-01")
      end
    end
    # A handover now refuses to strand Payments, so publish one from before it did.
    Rails.configuration.event_store.publish(
      OrgGraph::Events::LevelProviderSet.new(data: { level_id: @team, provider: "hibob", previous_provider: "espalia", field: "work.team",
                                                     effective_on: "2026-02-01", set_by_id: nil },
                                             metadata: { tenant_id: @tenant.id }),
      stream_name: EventStreamNaming.org_structure_stream(tenant: @tenant)
    )

    error = assert_raises(SystemExit) { run_task }
    assert_not error.success?
    assert_equal [ "Payments (Team) sits beneath Ops (Division), where its kind may not" ],
                 as_tenant { OrgGraph::TaxonomyCheck.new.misplaced }
  end

  should "report a change to the kinds dated before an earlier one, without failing" do
    as_tenant { @handler.add_level(SecureRandom.uuid_v7, "Squad", effective_on: "2025-12-01") }

    assert_match "0 misplaced units, 1 change to the kinds dated out of order", run_task
    assert_match(/TaxonomyDefined .+ is dated 2025-12-01, before 2026-01-01/, as_tenant { OrgGraph::TaxonomyCheck.new.out_of_order }.sole)
  end
end
