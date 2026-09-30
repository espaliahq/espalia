# frozen_string_literal: true

# A framework with two roles that share some cells and not others — the
# shape every role-lens test needs (ADR-22):
#
#   Software Engineer (E1–E3) and Product Manager (PM1–PM3), each binding
#   "Critical Thinking" (shared); E binds "Systems Design" alone and PM binds
#   "Roadmapping" alone. Every capability has an expectation at 1, 2 and 3.
#
# `enrol_in_role_lens_framework` assigns a person to E2 and enrols them in
# an open cycle through the real command handlers, so the enrollment
# snapshot, the progress row and the projection all exist.
module RoleLensFixture
  Framework = Struct.new(:framework, :engineer, :e_levels, :pm, :pm_levels,
                         :shared, :e_only, :pm_only, keyword_init: true) do
    def framework_id = framework.framework_id
  end

  # @param tenant [Tenant]
  # @return [RoleLensFixture::Framework]
  def build_role_lens_framework(tenant:)
    ActsAsTenant.with_tenant(tenant) do
      framework = create(:framework_state, framework_id: SecureRandom.uuid_v7, name: "Growth")
      eng = create(:framework_role_family, framework_id: framework.framework_id, name: "Engineering")
      product = create(:framework_role_family, framework_id: framework.framework_id, name: "Product")
      engineer = create(:framework_role, role_family_id: eng.role_family_id, name: "Software Engineer", code: "E")
      pm = create(:framework_role, role_family_id: product.role_family_id, name: "Product Manager", code: "PM")
      e_levels = (1..3).to_h do |i|
        [ i, create(:framework_level, role_id: engineer.role_id, ordinal: i, code: "E#{i}", title: "Engineer #{i}") ]
      end
      pm_levels = (1..3).to_h do |i|
        [ i, create(:framework_level, role_id: pm.role_id, ordinal: i, code: "PM#{i}", title: "Product Manager #{i}") ]
      end

      category = create(:framework_capability_category, framework_id: framework.framework_id, name: "Craft", ordinal: 1)
      shared = lens_capability(category, "Critical Thinking", [ engineer, pm ])
      e_only = lens_capability(category, "Systems Design", [ engineer ])
      pm_only = lens_capability(category, "Roadmapping", [ pm ])

      Framework.new(framework: framework, engineer: engineer, e_levels: e_levels, pm: pm, pm_levels: pm_levels,
                    shared: shared, e_only: e_only, pm_only: pm_only)
    end
  end

  # @param person [Person]
  # @param fixture [RoleLensFixture::Framework]
  # @param tenant [Tenant]
  # @return [Array(PersonFrameworkAssignment, String)] the assignment and cycle id
  def enrol_in_role_lens_framework(person, fixture, tenant:, level_ordinal: 2)
    ActsAsTenant.with_tenant(tenant) do
      PersonDevelopment::CommandHandler.new.assign_to_framework(
        person.id, fixture.framework_id, fixture.engineer.role_id, fixture.e_levels.fetch(level_ordinal).level_id
      )
      cycle_id = SecureRandom.uuid_v7
      cycles = AssessmentCycles::CommandHandler.new
      cycles.define_cycle(cycle_id, fixture.framework_id, "Q3 2026", "regular", 1)
      cycles.enroll(cycle_id, person.id)
      [ PersonFrameworkAssignment.find_by!(person_id: person.id, framework_id: fixture.framework_id), cycle_id ]
    end
  end

  private

  def lens_capability(category, name, roles)
    capability = create(:framework_capability, category_id: category.category_id, name: name)
    roles.each do |role|
      create(:framework_capability_role_binding, capability_id: capability.capability_id, role_id: role.role_id)
    end
    (1..3).each do |ordinal|
      create(:framework_behavioural_expectation, capability_id: capability.capability_id, level_ordinal: ordinal,
        description: "#{name} at level #{ordinal}")
    end
    capability
  end
end

ActiveSupport::TestCase.include(RoleLensFixture)
