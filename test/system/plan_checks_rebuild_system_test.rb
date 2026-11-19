# frozen_string_literal: true

require "application_system_test_case"

# While the Org Graph's structure is being rebuilt, the Checks tab says its
# fit check did not run rather than that everything fits
# ([#494](https://github.com/espaliahq/espalia/issues/494)).
class PlanChecksRebuildSystemTest < ApplicationSystemTestCase
  LINE = "[data-check-unchecked='misfits']"

  setup do
    @tenant = create(:tenant)
    structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    team = SecureRandom.uuid_v7
    travel_to(30.days.ago) do
      since = Date.current.iso8601
      ActsAsTenant.with_tenant(@tenant) do
        @admin = create(:tenant_user, tenant: @tenant, role: :admin, team_planner: true,
                                      user: create(:user, password: TEST_PASSWORD), person: create(:person, tenant: @tenant))
        structure.define_taxonomy([ { level_id: team, name: "Team" } ], effective_on: since)
        structure.create_unit(SecureRandom.uuid_v7, "Payments", level_id: team, effective_on: since)
      end
    end
    @plan_id = ActsAsTenant.with_tenant(@tenant) do
      Operations::TeamPlanning::CreatePlan.call(context: AuthorizationContext.new(user: @admin.user, tenant_user: @admin, person: @admin.person),
                                                params: { name: "Next year", base_on: Date.current.iso8601 })[:plan_id]
    end
  end

  def rebuilding_structure(&)
    structure = OrgGraph::Projections::Structure::PROJECTION_NAME
    rebuilding = lambda do |*names, &block|
      raise ProjectionVersion::Rebuilding if names.include?(structure)

      block.call
    end
    ProjectionVersion.stub(:unless_rebuilding, rebuilding, &)
  end

  def assert_unchecked_then_checked
    sign_in_as(@admin.user)
    rebuilding_structure do
      visit checks_plan_path(@plan_id)
      assert_selector LINE, text: "This check did not run: the Org Graph is being rebuilt. Try again in a minute."
      assert_selector "[data-checks-not-run='misfits']", text: "Unit types not checked: the Org Graph is being rebuilt."
      assert_no_text "Everything in this scenario still fits."
      assert_no_sideways_overflow
    end

    visit checks_plan_path(@plan_id)
    assert_text "Everything in this scenario still fits."
    assert_no_selector LINE
  end

  context "on a desktop" do
    setup { page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE) }

    should "say the fit check did not run while the structure is rebuilt" do
      assert_unchecked_then_checked
    end
  end

  context "on a phone" do
    setup { page.driver.browser.manage.window.resize_to(*MOBILE_SIZE) }

    should "say the fit check did not run, on a line that fits" do
      assert_unchecked_then_checked
    end
  end
end
