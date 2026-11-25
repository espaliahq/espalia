# frozen_string_literal: true

require "test_helper"

class TenantPlanningInputs::HistoryTest < ActiveSupport::TestCase
  should "know what every planning inputs event writes" do
    events = Dir[Rails.root.join("app/contexts/tenant_planning_inputs/events/*.rb")]
             .map { "TenantPlanningInputs::Events::#{File.basename(it, '.rb').camelize}".constantize }

    assert_equal events.sort_by(&:name), TenantPlanningInputs::History::WRITES.keys.sort_by(&:name)
  end
end
