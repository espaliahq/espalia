# frozen_string_literal: true

require "test_helper"

class Assessments::LensTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @framework_id = SecureRandom.uuid_v7
    create(:framework_state, framework_id: @framework_id)

    eng = create(:framework_role_family, framework_id: @framework_id, name: "Engineering")
    @engineer = create(:framework_role, role_family_id: eng.role_family_id, name: "Software Engineer", code: "E")
    @e_levels = (1..3).to_h { |i| [ i, create(:framework_level, role_id: @engineer.role_id, ordinal: i, code: "E#{i}") ] }

    product = create(:framework_role_family, framework_id: @framework_id, name: "Product")
    @pm = create(:framework_role, role_family_id: product.role_family_id, name: "Product Manager", code: "PM")
    [ 1, 3, 4 ].each { |i| create(:framework_level, role_id: @pm.role_id, ordinal: i, code: "PM#{i}") }

    @person_id = SecureRandom.uuid_v7
    @assignment = create(:person_framework_assignment, person_id: @person_id, framework_id: @framework_id,
      role_id: @engineer.role_id, level_id: @e_levels[2].level_id)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  context ".resolve" do
    should "read the assignment as itself without lens params" do
      lens = Assessments::Lens.resolve(assignment: @assignment)
      assert lens.home?
      assert_equal "E2", lens.code
      assert_equal({}, lens.to_params)
    end

    should "read another level of the home ladder" do
      lens = Assessments::Lens.resolve(assignment: @assignment, as_level: "3")
      assert_not lens.home?
      assert lens.home_role?
      assert_equal({ as_level: 3 }, lens.to_params)
      assert_equal 2, lens.assumed_below
    end

    should "read another role at the nearest level, lower on a tie" do
      lens = Assessments::Lens.resolve(assignment: @assignment, as_role: @pm.role_id)
      assert_equal "PM1", lens.code, "PM has no level 2; 1 and 3 tie and the lower wins"
      assert_equal "E2", lens.home_code
      assert_equal({ as_role: @pm.role_id, as_level: 1 }, lens.to_params)
    end

    should "take the level asked for" do
      lens = Assessments::Lens.resolve(assignment: @assignment, as_role: @pm.role_id, as_level: 4)
      assert_equal "Product Manager · PM4", lens.label
      assert_equal({ role_id: @pm.role_id, role_code: "PM", level_ordinal: 4, home: false,
                    cycle_id: nil, past_cycle: false }, lens.payload)
    end

    should "refuse a role from another framework" do
      other_family = create(:framework_role_family, framework_id: SecureRandom.uuid_v7, name: "Elsewhere")
      other = create(:framework_role, role_family_id: other_family.role_family_id, code: "X")
      assert_raises(Assessments::Lens::NotFound) do
        Assessments::Lens.resolve(assignment: @assignment, as_role: other.role_id)
      end
    end

    should "refuse a level the role doesn't have, or one that isn't a number" do
      assert_raises(Assessments::Lens::NotFound) { Assessments::Lens.resolve(assignment: @assignment, as_level: 9) }
      assert_raises(Assessments::Lens::NotFound) { Assessments::Lens.resolve(assignment: @assignment, as_level: "E3") }
    end

    should "take home from the open cycle's enrollment snapshot" do
      cycle = create(:assessment_cycle, framework_id: @framework_id)
      create(:assessment_cycle_enrollment, cycle: cycle, person_id: @person_id,
        role_id: @engineer.role_id, level_id: @e_levels[1].level_id, level_ordinal: 1)

      lens = Assessments::Lens.resolve(assignment: @assignment)
      assert_equal "E1", lens.home_code
      assert lens.home?
    end
  end

  context ".params_for" do
    should "name nothing for the home, only the level on the home ladder" do
      lens = Assessments::Lens.home(@assignment)
      assert_equal({}, lens.params_for(role_id: @engineer.role_id, ordinal: 2))
      assert_equal({ as_level: 1 }, lens.params_for(role_id: @engineer.role_id, ordinal: 1))
      assert_equal({ as_role: @pm.role_id, as_level: 3 }, lens.params_for(role_id: @pm.role_id, ordinal: 3))
    end
  end

  context Assessments::Disclosure do
    setup do
      category = create(:framework_capability_category, framework_id: @framework_id)
      @capability = create(:framework_capability, category_id: category.category_id)
      create(:framework_capability_role_binding, capability_id: @capability.capability_id, role_id: @engineer.role_id)
      create(:framework_behavioural_expectation, capability_id: @capability.capability_id, level_ordinal: 2)
      @lens = Assessments::Lens.resolve(assignment: @assignment, as_role: @pm.role_id, as_level: 3)
    end

    should "disclose the home scope once home alignment has started" do
      assert Assessments::Disclosure.for(lens: @lens, participant_status: "aligning")
        .include?(@capability.stable_id, 2)
    end

    should "disclose nothing before home alignment starts" do
      assert_not Assessments::Disclosure.for(lens: @lens, participant_status: "started")
        .include?(@capability.stable_id, 2)
    end
  end
end
