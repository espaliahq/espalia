# frozen_string_literal: true

require "test_helper"
require "rake"

class EventsReconcilePlanningInputsTaskTest < ActiveSupport::TestCase
  PROJECTION = TenantPlanningInputs::Projections::Tables
  TASKS = %w[events:reconcile events:projections:verify events:projections:rebuild].freeze

  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    TASKS.each { Rake::Task[it].reenable }
    @tenant = create(:tenant)
    # Written as the previous release writes them: straight to the tables.
    ActsAsTenant.with_tenant(@tenant) do
      %w[Fixtureland Elsewhere].each.with_index(1) do |location, position|
        PayBand.create!(location:, position:, currency: "AUD", period: "year", minimum: 1, midpoint: 2, maximum: 3,
                        role_name: "Every role", level_name: "Every level")
      end
      ReferenceCurrency.create!(currency: "AUD")
      ExchangeRate.create!(from_currency: "NZD", to_currency: "AUD", rate: "0.9", applies_from: "2026-07-01")
    end
    (Projections::Registry.classes - [ PROJECTION ]).each { ProjectionVersion.stamp!(it) }
    ProjectionVersion.where(name: PROJECTION::PROJECTION_NAME).delete_all
    @out = run_task("events:reconcile")
  end

  def run_task(task, *args)
    out, = capture_io { Rake::Task[task].invoke(*args) }
    Rake::Task[task].reenable
    out
  end

  def tables
    TenantPlanningInputs::Rows::TABLES.each_key.to_h do |table|
      [ table, TenantPlanningInputs::Rows.model(table).unscoped.where(tenant_id: @tenant.id).order(:id).map { it.attributes.except("updated_by_id") } ]
    end.merge(stamp: Tenant.where(id: @tenant.id).pick(:pay_bands_changed_at))
  end

  context "a deploy of the never-stamped tables" do
    should "adopt them once the stream holds what the tables hold, so verify passes without a rebuild" do
      assert_match "#{PROJECTION::PROJECTION_NAME}: adopted", @out
      assert_equal PROJECTION::CODE_VERSION, ProjectionVersion.find_by(name: PROJECTION::PROJECTION_NAME).version
      assert_match "OK", run_task("events:projections:verify")
    end

    should "adopt tables a rebuild from the stream writes back the same" do
      adopted = tables

      run_task("events:projections:rebuild", PROJECTION::PROJECTION_NAME)

      assert_equal adopted, tables
    end
  end
end
