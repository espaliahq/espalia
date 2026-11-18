# frozen_string_literal: true

require "test_helper"

# A manager's team as one set of capabilities, for the web's team card and an agent alike.
class Operations::Assessments::TeamCapabilitiesTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @fx = build_role_lens_framework(tenant: @tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @user = create(:user)
      @manager = create(:person, tenant: @tenant, email: @user.email)
      @tenant_user = create(:tenant_user, tenant: @tenant, user: @user, person: @manager, role: :member)
      @ada = create(:person, tenant: @tenant, name: "Ada Lark", manager: @manager)
      @bo = create(:person, tenant: @tenant, name: "Bo Finch", manager: @manager)
      @cy = create(:person, tenant: @tenant, name: "Cy Wren", manager: @ada)
    end
    rate(@ada, shared: "consistent", e_only: "consistent")
    rate(@bo, shared: "some", e_only: "consistent")
    rate(@cy, shared: "none", e_only: "consistent")
    @context = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @manager)
  end

  def call(context: @context, **params)
    ActsAsTenant.with_tenant(@tenant) { Operations::Assessments::TeamCapabilities.call(context:, params:) }
  end

  def row(result, capability) = result[:capabilities].find { |c| c[:stable_id] == capability.stable_id }

  should "score the direct reports on each capability by default, as percentages, naming nobody" do
    result = call

    assert_equal [ "direct", true, "manager" ], result.values_at(:people, :indirect_reports, :ratings)
    assert_equal [ 2, 2, 1 ], result.values_at(:in_view, :scored, :met)
    assert_equal({ name: "Critical Thinking", score: 67, scored: 2, short: 1 },
                 row(result, @fx.shared).slice(:name, :score, :scored, :short))
    assert_equal({ id: @fx.engineer.role_id, name: @fx.engineer.name }, result[:role])
    assert_no_match(/Ada|Bo Finch|Cy/, result.to_json)
  end

  should "widen to everyone below the manager" do
    result = call(people: "below")

    assert_equal 3, result[:in_view]
    assert_equal [ { stable_id: @fx.shared.stable_id, name: "Critical Thinking", short: 2, scored: 3 } ], result[:gaps]
  end

  should "never round a team score that is short of met up to 100" do
    ActsAsTenant.with_tenant(@tenant) do
      AssessmentLevelRating.where(person_id: @bo.id, capability_stable_id: @fx.shared.stable_id)
        .update_all(manager_rated_frequency: "consistent")
    end
    team = Operations::Assessments::TeamCapabilities.new(context: @context, params: {})
    team.define_singleton_method(:result) do
      @result ||= super().then { |r| r.with(capabilities: r.capabilities.map { |c| c.with(score: 0.996) }) }
    end

    assert_equal 99, ActsAsTenant.with_tenant(@tenant) { team.call }[:capabilities].first[:score]
  end

  should "read the self-ratings when asked" do
    assert_equal 0, call(ratings: "self")[:scored]
  end

  should "narrow to one level, listing each level's headcount" do
    result = call(level_ordinal: 3)

    assert_equal [ [ "E1", 0 ], [ "E2", 2 ], [ "E3", 0 ] ], result[:levels].map { |l| l.values_at(:code, :people) }
    assert_equal 0, result[:in_view]
  end

  should "say there are no indirect reports to widen to" do
    ActsAsTenant.with_tenant(@tenant) { @cy.update!(manager: @manager) }

    assert_not call[:indirect_reports]
  end

  context "compared with everyone on the role at the team's levels" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        snapshot = LevelComparisonSnapshot.create!(tenant: @tenant, taken_on: Date.new(2026, 11, 1))
        snapshot.groups.create!(tenant: @tenant, framework_id: @fx.framework_id, role_id: @fx.engineer.role_id,
                                level_ordinal: 2, group_size: 6, capability_medians: { @fx.shared.stable_id => 0.9 },
                                category_medians: {})
      end
    end

    should "give each capability the group's median, with the snapshot and group size" do
      result = call

      assert_equal({ shown: true, reason: nil, taken_on: "2026-11-01", min_group_size: 5, group_size: 6, short_levels: [] },
                   result[:comparison])
      assert_equal 90, row(result, @fx.shared)[:group_median]
      assert_nil row(result, @fx.e_only)[:group_median]
    end

    should "draw nothing when asked to compare with nothing" do
      result = call(compare: "none")

      assert_equal [ false, "none" ], result[:comparison].values_at(:shown, :reason)
      assert_nil row(result, @fx.shared)[:group_median]
      assert_equal %w[none level], [ result[:compare], call[:compare] ]
    end

    should "say which levels in view are too small to compare with" do
      @tenant.comparison_config.min_group_size = 7
      @tenant.save!

      assert_equal [ false, "too_few", [ "E2" ] ], call[:comparison].values_at(:shown, :reason, :short_levels)
    end
  end

  should "refuse a caller with no person" do
    context = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: nil)

    assert_raises(Pundit::NotAuthorizedError) { call(context:) }
  end

  private

  # The first person opens the cycle; assigning the rest enrols them in it, as a framework has one open cycle.
  def rate(person, shared:, e_only:)
    if @cycle_id
      enrol_in_open_cycle(person)
    else
      _, @cycle_id = enrol_in_role_lens_framework(person, @fx, tenant: @tenant)
    end
    cycle_id = @cycle_id
    ActsAsTenant.with_tenant(@tenant) do
      { @fx.shared => shared, @fx.e_only => e_only }.each do |capability, frequency|
        create(:assessment_level_rating, tenant: @tenant, cycle_id:, person_id: person.id,
                                         framework_id: @fx.framework_id, capability_stable_id: capability.stable_id,
                                         level_ordinal: 2, manager_rated_frequency: frequency)
      end
    end
  end

  def enrol_in_open_cycle(person)
    ActsAsTenant.with_tenant(@tenant) do
      level_id = @fx.e_levels.fetch(2).level_id
      PersonDevelopment::CommandHandler.new.assign_to_framework(person.id, @fx.framework_id, @fx.engineer.role_id, level_id)
    end
  end
end
