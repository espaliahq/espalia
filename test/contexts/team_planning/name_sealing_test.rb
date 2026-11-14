# frozen_string_literal: true

require "test_helper"

# Names stored in clear before #209 are sealed in place, and nothing else of
# the record moves.
class TeamPlanning::NameSealingTest < ActiveSupport::TestCase
  LEGACY = JSON.parse(Rails.root.join("test/fixtures/files/event_store/legacy_plan_names.json").read)
  FIXTURE_TENANT = "01a1d95d-7b58-71c7-b4a0-9a980c3e2b2b"
  LIVE_PLAN = "01a1d95d-7d14-7bef-a3cd-04d39d0e4ee4"
  ACTOR = "01a1d95d-7cea-70f5-aef9-85f2e797741b"
  NAMES = [ "Next year", "The year after", "Lean Q1", "Closing the office" ].freeze

  Stored = TeamPlanning::NameSealing::StoredEvent

  setup do
    @tenant = create(:tenant)
    @other = create(:tenant)
    @deleted_plan = SecureRandom.uuid_v7
    [ @tenant, @other ].each do |tenant|
      LEGACY.each { store(tenant, it["event_type"], it["data"], it["metadata"]) }
      store(tenant, "TeamPlanning::Events::ScenarioForked", JSON.generate(
        "plan_id" => LIVE_PLAN, "scenario_id" => SecureRandom.uuid_v7, "parent_id" => LIVE_PLAN, "relation" => "then",
        "name" => "Lean Q1", "starts_on" => "2026-11-14", "ends_on" => "2027-03-31", "forked_by_id" => ACTOR
      ))
      store(tenant, "TeamPlanning::Events::PlanCreated", JSON.generate(
        "plan_id" => @deleted_plan, "name" => "Closing the office", "base_on" => "2026-11-14", "created_by_id" => ACTOR
      ))
    end
    ActsAsTenant.with_tenant(@tenant) { PlanKeyStore.new.destroy_plan(@deleted_plan) }
    @before = rows(@tenant)
  end

  # Stores a record as a release before #209 wrote it: names in clear.
  def store(tenant, type, data, metadata = nil)
    metadata ||= JSON.generate("tenant_id" => FIXTURE_TENANT, "correlation_id" => SecureRandom.uuid,
                               "types" => { "data" => JSON.parse(data).keys.to_h { [ it, %w[Symbol String] ] },
                                            "metadata" => { "tenant_id" => %w[Symbol String], "correlation_id" => %w[Symbol String] } })
    Stored.create!(event_id: SecureRandom.uuid, event_type: type, data:, metadata: metadata.sub(FIXTURE_TENANT, tenant.id),
                   created_at: Time.current, valid_at: nil)
  end

  def rows(tenant) = Stored.order(:id).select { JSON.parse(it.metadata)["tenant_id"] == tenant.id }.map(&:attributes)

  def sealing = TeamPlanning::NameSealing.new(@tenant)

  def events = Rails.configuration.event_store.read.of_type(TeamPlanning::NameSealing::EVENT_TYPES).to_a
    .select { it.metadata[:tenant_id] == @tenant.id }

  should "count what it would seal, and change nothing" do
    counts = sealing.dry_run

    assert_equal({ "TeamPlanning::Events::PlanCreated" => 2, "TeamPlanning::Events::PlanRenamed" => 1,
                   "TeamPlanning::Events::ScenarioForked" => 1 }, counts)
    assert_equal @before, rows(@tenant)
  end

  should "seal every name, and leave every other byte of the record as it was" do
    sealing.seal!
    after = rows(@tenant)

    assert_equal @before.size, after.size
    @before.zip(after).each do |was, now|
      assert_equal was.except("data", "metadata"), now.except("data", "metadata"), "id, type and timestamps"
      fields = JSON.parse(now["metadata"])["shreddable"].keys

      old_data, new_data = JSON.parse(was["data"]), JSON.parse(now["data"])
      assert_equal JSON.generate(old_data.except(*fields)), JSON.generate(new_data.except(*fields))
      assert_equal old_data.keys, new_data.keys, "the fields keep their order"
      assert_equal was["data"], JSON.generate(old_data), "the fixture round-trips, so the comparison is byte for byte"

      old_meta, new_meta = JSON.parse(was["metadata"]), JSON.parse(now["metadata"])
      new_meta["types"]["metadata"].delete("shreddable")
      assert_equal was["metadata"], JSON.generate(new_meta.except("shreddable"))
      NAMES.each { assert_not_includes now["data"], it }
    end
  end

  should "read the names back sealed, a deleted plan's as removed" do
    sealing.seal!
    names = events.to_h { [ [ it.data[:plan_id], it.event_type.demodulize ], it.data[:name] ] }

    assert_equal "Next year", names[[ LIVE_PLAN, "PlanCreated" ]].reveal
    assert_equal "The year after", names[[ LIVE_PLAN, "PlanRenamed" ]].reveal
    assert_equal "Lean Q1", names[[ LIVE_PLAN, "ScenarioForked" ]].reveal
    assert_predicate names[[ @deleted_plan, "PlanCreated" ]], :removed?
    assert_equal "Next year", events.find { it.data[:previous_name] }.data[:previous_name].reveal
  end

  should "rebuild the plans and scenarios read models from the sealed names" do
    sealing.seal!

    ActsAsTenant.with_tenant(@tenant) do
      assert_equal "The year after", TeamPlanningPlan.find(LIVE_PLAN).name.reveal
      assert_predicate TeamPlanningPlan.find(@deleted_plan).name, :removed?
      assert_equal [ "Baseline", "Lean Q1" ], TeamPlanningScenario.where(plan_id: LIVE_PLAN).sort_by { it.baseline? ? 0 : 1 }.map { it.name.reveal }
    end
  end

  should "change nothing on a second run" do
    sealing.seal!
    sealed = rows(@tenant)

    assert_equal TeamPlanning::NameSealing::EVENT_TYPES.to_h { [ it.name, 0 ] }, sealing.seal!
    assert_equal sealed, rows(@tenant)
  end

  should "leave another tenant's records alone" do
    others = rows(@other)
    sealing.seal!

    assert_equal others, rows(@other)
  end
end
