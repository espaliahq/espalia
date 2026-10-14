# frozen_string_literal: true

require "test_helper"

# Bulk confirm of carried-forward ratings (#480): confirms only what is still
# carried, and never lets a stale list untoggle a rating someone already
# confirmed (re-sending a human value through RateSelf clears it).
class Operations::Assessments::ConfirmCarriedRatingsTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @user = create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      @person = create(:person, tenant: @tenant, email: @user.email, name: "Tester")
      @tenant_user = create(:tenant_user, tenant: @tenant, user: @user, person: @person, role: :member)

      framework_id = SecureRandom.uuid_v7
      @framework = create(:framework_state, framework_id: framework_id, name: "Eng")
      rf = create(:framework_role_family, framework_id: framework_id, name: "Engineering")
      @role  = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      @level = create(:framework_level, role_id: @role.role_id, ordinal: 2, title: "Mid", code: "E2")

      cat = create(:framework_capability_category, framework_id: framework_id, name: "Thinking", ordinal: 1)
      @cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
      create(:framework_capability_role_binding,
        capability_id: @cap.capability_id, role_id: @role.role_id, weight: 1.0)
      create(:framework_behavioural_expectation,
        capability_id: @cap.capability_id, level_ordinal: 2, description: "Synthesises")

      pd_handler = PersonDevelopment::CommandHandler.new
      cycles_handler = AssessmentCycles::CommandHandler.new
      pd_handler.assign_to_framework(@person.id, framework_id, @role.role_id, @level.level_id)

      @cycle_id = SecureRandom.uuid_v7
      cycles_handler.define_cycle(@cycle_id, framework_id, "Q1", "regular", 1, defined_by: @person.id)
      cycles_handler.enroll(@cycle_id, @person.id, enrolled_by: @person.id)

      @framework_id = framework_id
      @assignment = PersonFrameworkAssignment.for_person(@person.id).first
    end

    @context = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @person)
  end

  def seed(frequency, ordinal: 2, stable_id: @cap.stable_id)
    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.rate_self(
        @person.id, @framework_id, stable_id, level_ordinal: ordinal, frequency: frequency, cycle_id: @cycle_id,
        comment: "Seeded from prior cycle", source: "seeded", seeded_from_cycle_id: SecureRandom.uuid_v7
      )
    end
  end

  def confirm(cells, perspective: "self")
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Assessments::ConfirmCarriedRatings.call(context: @context, params: {
        assignment_id: @assignment.id, perspective: perspective, cells: cells
      })
    end
  end

  def row
    ActsAsTenant.with_tenant(@tenant) do
      AssessmentLevelRating.find_by!(cycle_id: @cycle_id, person_id: @person.id,
                                     capability_stable_id: @cap.stable_id, level_ordinal: 2)
    end
  end

  def cell = { "capability_stable_id" => @cap.stable_id, "level_ordinal" => 2 }

  should "confirm a carried rating, keeping its value" do
    seed("occasional")

    result = confirm([ cell ])

    assert_equal 1, result[:confirmed].size
    assert_equal "occasional", row.self_rated_frequency
    assert_equal "human", row.self_rating_source
  end

  should "skip a rating already confirmed rather than clearing it" do
    seed("occasional")
    confirm([ cell ])

    result = confirm([ cell ])

    assert_equal [ "not carried" ], result[:skipped].map { |skip| skip[:reason] }
    assert_equal "occasional", row.self_rated_frequency, "a stale list must never untoggle a confirmed rating"
  end

  should "skip a cell with no rating at all" do
    result = confirm([ cell ])

    assert_empty result[:confirmed]
    assert_equal "not carried", result[:skipped].first[:reason]
  end

  should "skip a cell the role doesn't read, with the reason, and still confirm the rest" do
    seed("occasional")
    stray = { "capability_stable_id" => SecureRandom.uuid_v7, "level_ordinal" => 2 }
    seed("consistent", stable_id: stray["capability_stable_id"])

    result = confirm([ stray, cell ])

    assert_equal [ @cap.stable_id ], result[:confirmed].map { |c| c[:capability_stable_id] }
    assert_match(/no expectation/, result[:skipped].first[:reason])
  end

  should "refuse the manager side to someone who isn't the manager" do
    seed("occasional")

    assert_raises(Pundit::NotAuthorizedError) { confirm([ cell ], perspective: "manager") }
  end

  should "confirm a cell listed twice once, never untoggling it" do
    seed("occasional")

    result = confirm([ cell, cell ])

    assert_equal 1, result[:confirmed].size
    assert_equal "occasional", row.self_rated_frequency
    assert_equal "human", row.self_rating_source
  end

  should "reject a malformed cell as a parameter error" do
    assert_raises(Operations::Base::ParameterError) do
      confirm([ { "capability_stable_id" => @cap.stable_id, "level_ordinal" => 2, "frequency" => "some" } ])
    end
    assert_raises(Operations::Base::ParameterError) { confirm([ { "capability_stable_id" => @cap.stable_id } ]) }
    assert_raises(Operations::Base::ParameterError) { confirm([ [ @cap.stable_id, 2 ] ]) }
  end
end
