# frozen_string_literal: true

require "test_helper"

class TenantPlanningInputs::HistoryTest < ActiveSupport::TestCase
  should "know what every planning inputs event writes" do
    events = Dir[Rails.root.join("app/contexts/tenant_planning_inputs/events/*.rb")]
             .map { "TenantPlanningInputs::Events::#{File.basename(it, '.rb').camelize}".constantize }

    assert_equal events.sort_by(&:name), TenantPlanningInputs::History::WRITES.keys.sort_by(&:name)
  end

  context "#changes" do
    setup do
      @tenant = create(:tenant)
      ActsAsTenant.current_tenant = @tenant
    end

    teardown { ActsAsTenant.current_tenant = nil }

    should "put a row reconcile recorded later below a change made after the row's own" do
      made = add_planning_input!(:exchange_rates, from_currency: "NZD", to_currency: "AUD", rate: 1, applies_from: Date.current)
      held = ExchangeRate.create!(from_currency: "USD", to_currency: "AUD", rate: 2, applies_from: Date.current)
      held.update_columns(updated_at: 1.day.ago)
      TenantPlanningInputs::Reconciliation.new(@tenant).call

      changes = TenantPlanningInputs::History.new(inputs: :exchange_rates).changes

      assert_equal [ made.id, held.id ], changes.map(&:row_id)
      assert_equal [ false, true ], changes.map(&:already_held)
    end

    should "put the later of two changes made at the same moment first" do
      first, second = freeze_time do
        %w[NZD USD].map { add_planning_input!(:exchange_rates, from_currency: it, to_currency: "AUD", rate: 1, applies_from: Date.current) }
      end

      assert_equal [ second.id, first.id ], TenantPlanningInputs::History.new(inputs: :exchange_rates).changes.map(&:row_id)
    end
  end
end
