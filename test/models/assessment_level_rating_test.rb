# frozen_string_literal: true

require "test_helper"

class AssessmentLevelRatingTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @framework_id = SecureRandom.uuid_v7
    @cycle = create(:assessment_cycle, tenant: @tenant, framework_id: @framework_id, framework_version: 1)
    @engineer_cap = SecureRandom.uuid_v7
    @manager_cap = SecureRandom.uuid_v7
    @alice = SecureRandom.uuid_v7
    @bob = SecureRandom.uuid_v7

    @engineer = scope_of("engineer", [ @engineer_cap, 2 ])
    @manager = scope_of("manager", [ @manager_cap, 2 ])
  end

  teardown { ActsAsTenant.current_tenant = nil }

  context ".within" do
    should "keep only the cells in one role's scope" do
      inside = rate(@alice, @engineer_cap, 2)
      rate(@alice, @manager_cap, 2)
      rate(@alice, @engineer_cap, 3)

      assert_equal [ inside ], AssessmentLevelRating.within(@engineer).to_a
    end

    should "compose with the relation it is called on" do
      rate(@alice, @engineer_cap, 2)
      bobs = rate(@bob, @engineer_cap, 2)

      assert_equal [ bobs ], AssessmentLevelRating.for_person(@bob).within(@engineer).to_a
    end

    should "read each person through their own scope when given a map" do
      alice_in = rate(@alice, @engineer_cap, 2)
      rate(@alice, @manager_cap, 2)
      bob_in = rate(@bob, @manager_cap, 2)
      rate(@bob, @engineer_cap, 2)

      rows = AssessmentLevelRating.for_cycle(@cycle.cycle_id)
        .within(@alice => @engineer, @bob => @manager)
      assert_equal [ alice_in, bob_in ].map(&:id).sort, rows.pluck(:id).sort
    end

    should "read nothing through an empty scope" do
      rate(@alice, @engineer_cap, 2)

      assert_empty AssessmentLevelRating.within(Assessments::RoleScope.empty(framework_id: @framework_id))
      assert_empty AssessmentLevelRating.within(@alice => Assessments::RoleScope.empty(framework_id: @framework_id))
      assert_empty AssessmentLevelRating.within({})
    end
  end

  context ".across_all_roles" do
    should "read every rating" do
      rate(@alice, @engineer_cap, 2)
      rate(@alice, @manager_cap, 2)

      assert_equal 2, AssessmentLevelRating.across_all_roles.count
    end
  end

  private

  def scope_of(role_id, *cells)
    Assessments::RoleScope.new(role_id: role_id, framework_id: @framework_id, bindings: [], cells: cells)
  end

  def rate(person_id, stable_id, ordinal)
    create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle.cycle_id, person_id: person_id,
      framework_id: @framework_id, capability_stable_id: stable_id, level_ordinal: ordinal,
      self_rated_frequency: "consistent")
  end
end
