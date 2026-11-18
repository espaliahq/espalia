# frozen_string_literal: true

require "test_helper"

# The team capability map: large team blades and a lane per capability, read
# through the same operation as the team card.
class Assessments::TeamMapsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @fx = build_role_lens_framework(tenant: @tenant)
    @user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      @manager = create(:person, tenant: @tenant, email: @user.email, name: "Morgan Vale")
      create(:tenant_user, tenant: @tenant, user: @user, person: @manager)
    end
    team = [ [ "Ada Lark", 2, "consistent" ], [ "Bo Finch", 2, "none" ], [ "Cy Wren", 3, "some" ] ]
    team.each { |name, level, frequency| add_report(name, level, frequency) }
  end

  should "draw the team's blades and a lane per capability, giving the team's score and how many are short" do
    sign_in @user
    get team_map_assessments_path

    assert_response :success
    assert_select "turbo-frame#team-map"
    assert_select "#team-map [data-team-blades]", count: 1
    assert_select "#team-map [data-team-lane='#{@fx.shared.stable_id}']", text: /Critical Thinking.*Team 44%.*2 short/m
    assert_select "#team-map", text: /Your 3 direct reports, manager ratings/
    assert_no_match(/Ada Lark|Bo Finch|Cy Wren/, response.body)
  end

  should "filter to one level with chips that count the people at each" do
    sign_in @user
    get team_map_assessments_path(team_level: 3)

    assert_select "#team-map a[data-team-level]", text: /E2\s*2/
    assert_select "#team-map a[data-team-level][aria-current='page']", text: /E3\s*1/
    assert_select "#team-map [data-team-lane='#{@fx.shared.stable_id}']", text: /Team 33%.*1 short/m
  end

  should "show the ratings it reads, and switch to self-ratings" do
    sign_in @user
    get team_map_assessments_path(team_ratings: "self")

    assert_select "#team-map", text: /Your 3 direct reports, self-ratings/
    assert_select "#team-map a[aria-current='page']", text: "Self"
  end

  context "compared with everyone on the role at the team's levels" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        @snapshot = LevelComparisonSnapshot.create!(tenant: @tenant, taken_on: Date.new(2026, 11, 1))
        { 2 => 6, 3 => 5 }.each do |level, size|
          @snapshot.groups.create!(tenant: @tenant, framework_id: @fx.framework_id, role_id: @fx.engineer.role_id,
                                   level_ordinal: level, group_size: size, category_medians: {},
                                   capability_medians: { @fx.shared.stable_id => level == 2 ? 0.9 : 0.6 })
        end
      end
      sign_in @user
    end

    should "draw a line across each blade and name the group's score in each lane" do
      get team_map_assessments_path

      assert_select "#team-map [data-team-blades] [data-blade-median]", count: 1
      assert_select "#team-map [data-team-lane='#{@fx.shared.stable_id}']", text: /Team 44%.*Group 80%.*2 short/m
      assert_select "#team-map a[aria-current='page']", text: "Software Engineers at the same levels"
      assert_select "#team-map", text: /11 Software Engineers at E2 and E3, as of 1 Nov 2026/
    end

    should "remove the line when compared with nothing" do
      get team_map_assessments_path(team_compare: "none")

      assert_select "#team-map [data-blade-median]", count: 0
      assert_select "#team-map a[aria-current='page']", text: "Nothing"
    end

    should "say why there is no line when a level in view is under the minimum" do
      ActsAsTenant.with_tenant(@tenant) { @snapshot.groups.find_by!(level_ordinal: 3).update!(group_size: 2) }
      get team_map_assessments_path

      assert_select "#team-map [data-blade-median]", count: 0
      assert_select "#team-map [data-team-compare-note]", text: /Fewer than 5 Software Engineers at E3/
    end
  end

  should "send someone signed out to sign in" do
    get team_map_assessments_path

    assert_redirected_to new_user_session_path
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end

  # Assigning a report into the framework enrols them in its open cycle, which the first one opens.
  def add_report(name, level, frequency)
    ActsAsTenant.with_tenant(@tenant) do
      report = create(:person, tenant: @tenant, name:, manager: @manager)
      if @cycle_id
        PersonDevelopment::CommandHandler.new.assign_to_framework(report.id, @fx.framework_id, @fx.engineer.role_id,
                                                                   @fx.e_levels.fetch(level).level_id)
      else
        _, @cycle_id = enrol_in_role_lens_framework(report, @fx, tenant: @tenant, level_ordinal: level)
      end
      [ @fx.shared, @fx.e_only ].each do |capability|
        create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle_id, person_id: report.id,
                                         framework_id: @fx.framework_id, capability_stable_id: capability.stable_id,
                                         level_ordinal: level, manager_rated_frequency: frequency)
      end
    end
  end
end
