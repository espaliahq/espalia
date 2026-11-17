# frozen_string_literal: true

require "test_helper"

# Guards #469: a business date is the tenant's today, read through
# Tenant#today, and never the server's UTC date. A tenant ten hours ahead of
# UTC lives in tomorrow for ten hours of every day.
class TenantTodayGuardTest < ActiveSupport::TestCase
  BARE_TODAY = /
    \bDate\.(?:current|today|yesterday|tomorrow)\b |
    \bTime\.zone\.today\b |
    \bDateTime\.now\b |
    \bTime\.(?:now|current)(?:\.utc)?\.to_date\b
  /x

  # Files still to be routed through Tenant#today. This list only shrinks,
  # and #469's last slice empties it.
  PENDING = %w[
    app/contexts/org_graph/forgetting.rb
    app/contexts/org_graph/people_cutover.rb
    app/contexts/org_graph/person_aggregate.rb
    app/controllers/concerns/org_graph_drawer.rb
    app/controllers/concerns/org_unit_drawer.rb
    app/controllers/tenant/org_people_controller.rb
    app/controllers/tenant/org_units_controller.rb
    app/integrations/hris/hibob/adapter.rb
    app/models/org_graph_config.rb
    app/models/pay_band.rb
    app/models/tenant.rb
    app/operations/operations/org_graph/confirm_fact.rb
    app/operations/operations/org_graph/set_fact_provider.rb
    app/operations/operations/org_graph/unit_write.rb
    app/queries/org_graph/date_comparison.rb
    app/queries/org_graph/person_profile.rb
    app/queries/team_planning/attention.rb
    app/read_models/org_leaver.rb
    app/views/evidence/conversation_chrome.rb
    app/views/tenant/org_graph/activity_sidebar.rb
    app/views/tenant/org_graph/comparison_bar.rb
    app/views/tenant/org_graph/unit_step.rb
  ].freeze

  test "no business date reads the server's clock outside Tenant#today" do
    offenders = files_reading_the_clock - PENDING

    assert_empty offenders, <<~MSG
      These files read today's date without the tenant's time zone:
        #{offenders.join("\n  ")}
      Use tenant.today (Tenant#today) instead, so a tenant ahead of or behind UTC gets its own day.
    MSG
  end

  test "the pending list holds only files that still read the clock" do
    routed = PENDING - files_reading_the_clock

    assert_empty routed, "Routed through Tenant#today, so take them off PENDING: #{routed.join(', ')}"
  end

  private

  def files_reading_the_clock
    Dir[Rails.root.join("app/**/*.rb")].filter_map do |path|
      relative = Pathname(path).relative_path_from(Rails.root).to_s
      relative if File.read(path).match?(BARE_TODAY)
    end
  end
end
