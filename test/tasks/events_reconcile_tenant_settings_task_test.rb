# frozen_string_literal: true

require "test_helper"
require "rake"

class EventsReconcileTenantSettingsTaskTest < ActiveSupport::TestCase
  PROJECTION = TenantSettings::Projections::Retention
  TASKS = %w[events:reconcile events:projections:verify events:projections:rebuild].freeze

  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    TASKS.each { Rake::Task[it].reenable }
    @changed = create(:tenant)
    @untouched = create(:tenant)
    admin = ActsAsTenant.with_tenant(@changed) { create(:tenant_user, tenant: @changed, role: :admin, person: create(:person, tenant: @changed)) }
    # The previous release wrote the JSON alone, before the stream existed.
    Tenant.find(@changed.id).tap do
      it.org_graph_config.assign_attributes(retention_years: 4, scheduled_forgetting: true,
                                            scheduled_forgetting_enabled_at: Time.utc(2026, 11, 2, 9),
                                            scheduled_forgetting_enabled_by_id: admin.id)
    end.save!
    (Projections::Registry.classes - [ PROJECTION ]).each { ProjectionVersion.stamp!(it) }
    ProjectionVersion.where(name: PROJECTION::PROJECTION_NAME).delete_all
    @out = run_task("events:reconcile")
  end

  def run_task(task, *args)
    out, = capture_io { Rake::Task[task].invoke(*args) }
    Rake::Task[task].reenable
    out
  end

  def rows = TenantRetentionSetting.unscoped.where(tenant_id: [ @changed.id, @untouched.id ]).order(:tenant_id).map(&:attributes)

  should "adopt the projection once the stream holds what the JSON holds, so verify passes without a rebuild" do
    assert_match "tenant_settings [#{@changed.id}] recorded 0 already held, 0 removed, 1 changed", @out
    assert_match "#{PROJECTION::PROJECTION_NAME}: adopted", @out
    assert_match "OK", run_task("events:projections:verify")
  end

  should "adopt rows a rebuild from the stream writes back the same" do
    adopted = rows
    assert_equal [ @changed.id ], adopted.map { it["tenant_id"] }

    run_task("events:projections:rebuild", PROJECTION::PROJECTION_NAME)

    assert_equal adopted.map { it.except("created_at", "updated_at") }, rows.map { it.except("created_at", "updated_at") }
  end
end
