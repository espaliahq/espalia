# frozen_string_literal: true

require "test_helper"

class Assessments::RoleScopeTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant

    @framework_id = SecureRandom.uuid_v7
    create(:framework_state, framework_id: @framework_id)
    family = create(:framework_role_family, framework_id: @framework_id)
    @engineer = create(:framework_role, role_family_id: family.role_family_id, code: "E")
    @manager = create(:framework_role, role_family_id: family.role_family_id, code: "EM")
    @category = create(:framework_capability_category, framework_id: @framework_id)

    @shared = capability("Shared", roles: [ @engineer, @manager ], ordinals: [ 1, 2 ])
    @people_only = capability("People", roles: [ @manager ], ordinals: [ 2 ])
    @archived = capability("Archived", roles: [ @engineer ], ordinals: [ 1 ], status: "archived")
    @unwritten = capability("Unwritten", roles: [ @engineer ], ordinals: [])
  end

  teardown { ActsAsTenant.current_tenant = nil }

  context ".for" do
    should "hold the cells where an active bound capability carries an expectation" do
      scope = role_scope(@engineer)

      assert_equal Set[[ @shared.stable_id, 1 ], [ @shared.stable_id, 2 ]], scope.cells
      assert scope.include?(@shared.stable_id, 2)
      assert_not scope.include?(@people_only.stable_id, 2), "bound only to another role"
      assert_not scope.include?(@archived.stable_id, 1), "archived capabilities read nothing"
    end

    should "carry the role's active bindings for scoring, capability loaded" do
      bindings = role_scope(@engineer).bindings

      assert_equal [ @shared.capability_id, @unwritten.capability_id ].sort, bindings.map(&:capability_id).sort
      assert bindings.all? { |b| b.association(:capability).loaded? }
    end

    should "be empty for a role with nothing bound" do
      family = FrameworkState::RoleFamily.find_by(framework_id: @framework_id)
      lonely = create(:framework_role, role_family_id: family.role_family_id, code: "X")

      assert role_scope(lonely).empty?
    end
  end

  context "#at_level" do
    should "narrow cells, stable ids and bindings to one level" do
      scope = role_scope(@manager).at_level(2)

      assert_equal Set[[ @shared.stable_id, 2 ], [ @people_only.stable_id, 2 ]], scope.cells
      assert_equal Set[@shared.stable_id, @people_only.stable_id], scope.capability_stable_ids
      assert_equal 2, scope.bindings.size
      assert_equal @manager.role_id, scope.role_id
    end
  end

  context ".for_roles" do
    should "load every requested role, one scope each" do
      scopes = Assessments::RoleScope.for_roles(
        role_ids: [ @engineer.role_id, @manager.role_id, nil ], framework_id: @framework_id
      )

      assert_equal [ @engineer.role_id, @manager.role_id ], scopes.keys
      assert_equal 3, scopes[@manager.role_id].cells.size
    end
  end

  context ".reusing" do
    should "hand back the scope built earlier in the block" do
      Assessments::RoleScope.reusing do
        first = role_scope(@engineer)
        assert_same first, role_scope(@engineer)
        assert_same first, Assessments::RoleScope.for_roles(role_ids: [ @engineer.role_id, @manager.role_id ],
                                                            framework_id: @framework_id)[@engineer.role_id]
      end
    end

    should "build fresh outside a block, and after one ends" do
      assert_not_same role_scope(@engineer), role_scope(@engineer)
      Assessments::RoleScope.reusing { role_scope(@engineer) }
      assert_not_same role_scope(@engineer), role_scope(@engineer)
    end

    should "keep the outer block's scopes through a nested one" do
      Assessments::RoleScope.reusing do
        first = role_scope(@engineer)
        Assessments::RoleScope.reusing { assert_same first, role_scope(@engineer) }
        assert_same first, role_scope(@engineer)
      end
    end

    should "load only the roles it hasn't built yet" do
      Assessments::RoleScope.reusing do
        engineer = role_scope(@engineer)
        both = Assessments::RoleScope.for_roles(role_ids: [ @engineer.role_id, @manager.role_id ], framework_id: @framework_id)
        assert_same engineer, both[@engineer.role_id]
        assert_equal Set[[ @shared.stable_id, 1 ], [ @shared.stable_id, 2 ], [ @people_only.stable_id, 2 ]],
                     both[@manager.role_id].cells
      end
    end

    should "drop its scopes after a framework write" do
      Assessments::RoleScope.reusing do
        first = role_scope(@engineer)
        Frameworks::Repository.new.with_framework(@framework_id) { |_aggregate| }
        assert_not_same first, role_scope(@engineer)
      end
    end

    should "forget its scopes when the block raises" do
      assert_raises(RuntimeError) { Assessments::RoleScope.reusing { role_scope(@engineer); raise "boom" } }
      assert_not_same role_scope(@engineer), role_scope(@engineer)
    end
  end

  context ".for_people" do
    setup do
      @cycle = create(:assessment_cycle, tenant: @tenant, framework_id: @framework_id, framework_version: 1)
      @person_id = SecureRandom.uuid_v7
    end

    should "use the enrollment snapshot role over the live assignment" do
      assign(@person_id, @engineer)
      enroll(@person_id, @manager)

      assert_equal @manager.role_id, scopes_for(@person_id).fetch(@person_id).role_id
    end

    should "fall back to the live assignment when the snapshot predates the role column" do
      assign(@person_id, @engineer)
      enroll(@person_id, nil)

      assert_equal @engineer.role_id, scopes_for(@person_id).fetch(@person_id).role_id
    end

    should "give an unknown person an empty scope" do
      assert scopes_for(@person_id).fetch(@person_id).empty?
    end

    should "share one scope between people in the same role" do
      other_id = SecureRandom.uuid_v7
      enroll(@person_id, @manager)
      enroll(other_id, @manager)

      scopes = scopes_for(@person_id, other_id)
      assert_equal scopes[@person_id], scopes[other_id]
      assert_equal 1, scopes.values.group_by(&:itself).size
    end
  end

  private

  def role_scope(role)
    Assessments::RoleScope.for(role_id: role.role_id, framework_id: @framework_id)
  end

  def scopes_for(*person_ids)
    Assessments::RoleScope.for_people(cycle_id: @cycle.cycle_id, framework_id: @framework_id, person_ids: person_ids)
  end

  def capability(name, roles:, ordinals:, status: "active")
    cap = create(:framework_capability, category_id: @category.category_id, name: name, status: status)
    roles.each { |role| create(:framework_capability_role_binding, capability_id: cap.capability_id, role_id: role.role_id) }
    ordinals.each do |ordinal|
      create(:framework_behavioural_expectation, capability_id: cap.capability_id, level_ordinal: ordinal)
    end
    cap
  end

  def assign(person_id, role)
    level = create(:framework_level, role_id: role.role_id, ordinal: 2)
    create(:person_framework_assignment, tenant: @tenant, person_id: person_id, framework_id: @framework_id,
      role_id: role.role_id, level_id: level.level_id)
  end

  def enroll(person_id, role)
    AssessmentCycleEnrollment.create!(
      tenant: @tenant, cycle_id: @cycle.cycle_id, person_id: person_id,
      status: "enrolled", enrolled_at: Time.current, role_id: role&.role_id, level_ordinal: 2
    )
  end
end
