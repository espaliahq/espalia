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

  should "keep the map out of the browser's cache" do
    sign_in @user
    get team_map_assessments_path

    assert_equal "no-store", response.headers["Cache-Control"]
  end

  should "filter to one level with chips that count the people at each" do
    sign_in @user
    get team_map_assessments_path(team_level: 3)

    assert_select "#team-map a[data-team-level]", text: /E2\s*2/
    assert_select "#team-map a[data-team-level][aria-current='page']", text: /E3\s*1/
    assert_select "#team-map [data-team-lane='#{@fx.shared.stable_id}']", text: /Team 33%.*1 short/m
  end

  should "draw no lanes until two reports on the role have a score, as the card shows none" do
    ActsAsTenant.with_tenant(@tenant) do
      AssessmentLevelRating.where(person_id: Person.where(name: [ "Bo Finch", "Cy Wren" ]).select(:id)).delete_all
    end
    sign_in @user
    get team_map_assessments_path

    assert_response :success
    assert_select "#team-map", text: /Shows once at least two of your reports have a score/
    assert_select "#team-map [data-team-lane]", count: 0
    assert_select "#team-map [data-team-blades]", count: 0
  end

  should "draw one level's lanes when the role has two scores, even with one at that level" do
    sign_in @user
    get team_map_assessments_path(team_level: 3)

    assert_select "#team-map [data-team-lane='#{@fx.shared.stable_id}']", text: /Team 33%/
  end

  should "keep the role shown in its links when the team holds only one" do
    sign_in @user
    get team_map_assessments_path

    assert_select "#team-map a[data-team-level='E3'][href*='team_role=#{@fx.engineer.role_id}']"
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
                                   capability_medians: { @fx.shared.stable_id => level == 2 ? 0.9 : 0.6 },
                                   capability_counts: { @fx.shared.stable_id => size, @fx.e_only.stable_id => size })
        end
      end
      sign_in @user
    end

    should "draw a line across each blade and name the group's score in each lane" do
      get team_map_assessments_path

      assert_select "#team-map [data-team-blades] [data-blade-median]", count: 1
      assert_select "#team-map [data-team-lane='#{@fx.shared.stable_id}']", text: /Team 44%.*Group 80%.*2 short/m
      assert_select "#team-map a[aria-current='page']", text: /Software Engineers at the same levels/
      assert_select "#team-map", text: /11 Software Engineers at E2 and E3, as of 1 Nov 2026/
    end

    should "name the group's score in a lane the team hasn't rated" do
      ActsAsTenant.with_tenant(@tenant) do
        @snapshot.groups.each { |g| g.update!(capability_medians: g.capability_medians.merge(@fx.e_only.stable_id => 0.8)) }
        AssessmentLevelRating.where(capability_stable_id: @fx.e_only.stable_id).delete_all
      end
      get team_map_assessments_path

      assert_select "#team-map [data-team-lane='#{@fx.e_only.stable_id}']", text: /Team not rated · Group 80%/
    end

    should "say the group has no score in a lane fewer than the minimum were scored on" do
      ActsAsTenant.with_tenant(@tenant) do
        @snapshot.groups.find_by!(level_ordinal: 3).update!(capability_counts: { @fx.shared.stable_id => 4 })
        @snapshot.groups.find_by!(level_ordinal: 2).update!(capability_counts: { @fx.shared.stable_id => 4 })
      end
      get team_map_assessments_path

      assert_select "#team-map [data-blade-median]", count: 0
      assert_select "#team-map [data-team-lane='#{@fx.shared.stable_id}']", text: /Team 44% · Group no score · 2 short/
    end

    should "keep the choices it can read when another is one it can't, comparing as by default" do
      get team_map_assessments_path(team_ratings: "self", team_level: 3, team_compare: "everyone")

      assert_select "#team-map", text: /Your 1 direct report at E3, self-ratings/
      assert_select "#team-map a[data-team-level][aria-current='page']", text: /E3\s*1/
      assert_select "#team-map a[aria-current='page']", text: /Software Engineers at the same levels/
    end

    should "remove the line when compared with nothing" do
      get team_map_assessments_path(team_compare: "none")

      assert_select "#team-map [data-blade-median]", count: 0
      assert_select "#team-map a[aria-current='page']", text: "Nothing"
    end

    should "say nothing about the line at a level nobody in view is at" do
      get team_map_assessments_path(team_level: 1)

      assert_select "#team-map [data-team-compare-note]", count: 0
    end

    should "say no report matches a level nobody in view is at, rather than that nobody has a score" do
      get team_map_assessments_path(team_level: 1)

      assert_select "#team-map", text: /No reports match this level/
      assert_select "#team-map", text: /Nobody in view has a score yet/, count: 0
    end

    should "say why there is no line when a level in view is under the minimum" do
      ActsAsTenant.with_tenant(@tenant) { @snapshot.groups.find_by!(level_ordinal: 3).update!(group_size: 2) }
      get team_map_assessments_path

      assert_select "#team-map [data-blade-median]", count: 0
      assert_select "#team-map [data-team-compare-note]", text: /Fewer than 5 Software Engineers at E3/
    end
  end

  should "read every level for a level it can't read" do
    sign_in @user
    get team_map_assessments_path(team_level: [ "3" ])

    assert_response :success
    assert_select "#team-map", text: /Your 3 direct reports, manager ratings/
  end

  should "draw the map in the same number of queries, however large the team" do
    sign_in @user
    three = count_queries { get team_map_assessments_path }
    add_report("Eli Moss", 2, "consistent")
    add_report("Fen Hart", 3, "none")
    five = count_queries { get team_map_assessments_path }

    assert_select "#team-map", text: /Your 5 direct reports/
    assert_equal three, five
  end

  should "send someone signed out to sign in" do
    get team_map_assessments_path

    assert_redirected_to new_user_session_path
  end

  should "refuse an account with no linked person inside the frame, drawing no lanes" do
    stranger = create(:user, password: "password123")
    create(:tenant_user, tenant: @tenant, user: stranger)
    Person.stub(:create_or_find_by!, ->(*) { raise ActiveRecord::RecordInvalid }) do
      sign_in stranger
      get team_map_assessments_path, headers: { "Turbo-Frame" => "team-map" }
    end

    assert_select "turbo-frame#team-map", text: /You don't have access to this section/
    assert_select "[data-team-lane]", count: 0
  end

  private

  def count_queries(&)
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" }
    ActiveRecord::Base.uncached { ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &) }
    count
  end

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
