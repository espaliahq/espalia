# frozen_string_literal: true

# A rating every home-role reader must ignore (ADR-22): on a capability bound
# only to a role the person does not hold, at the person's ASSESSED level.
#
# Same level on purpose. Most readers already filter by the assessed ordinal,
# so a rating at another level proves nothing; one at the same level is the
# case an ordinal filter lets through. Use it in an "ignores ratings outside
# the assessed role" test beside every rating reader, and check the test
# fails with the reader's `.within` removed.
module OutOfScopeRatings
  # @param person_id [String]
  # @param cycle [AssessmentCycle]
  # @param level_ordinal [Integer] the person's assessed level
  # @param framework_id [String] defaults to the cycle's framework
  # @param attributes [Hash] rating overrides; every side defaults to
  #   "consistent" and human-owned, so whichever side a reader counts is set
  # @return [AssessmentLevelRating]
  def create_out_of_scope_rating(person_id:, cycle:, level_ordinal:, framework_id: cycle.framework_id, **attributes)
    tenant = ActsAsTenant.current_tenant || cycle.tenant
    family = create(:framework_role_family, tenant: tenant, framework_id: framework_id, name: "Elsewhere")
    other_role = create(:framework_role, tenant: tenant, role_family_id: family.role_family_id,
      name: "Other role", code: "OR")
    category = create(:framework_capability_category, tenant: tenant, framework_id: framework_id,
      name: "Other role only")
    capability = create(:framework_capability, tenant: tenant, category_id: category.category_id, name: "Out of scope")
    create(:framework_capability_role_binding, tenant: tenant, capability_id: capability.capability_id,
      role_id: other_role.role_id)
    create(:framework_behavioural_expectation, tenant: tenant, capability_id: capability.capability_id,
      level_ordinal: level_ordinal)

    create(:assessment_level_rating, {
      tenant: tenant, cycle_id: cycle.cycle_id, person_id: person_id,
      framework_id: framework_id, capability_stable_id: capability.stable_id, level_ordinal: level_ordinal,
      self_rated_frequency: "consistent", manager_rated_frequency: "consistent", aligned_frequency: "consistent",
      self_rating_source: "human", manager_rating_source: "human",
      last_self_rated_at: Time.current, last_manager_rated_at: Time.current
    }.merge(attributes))
  end
end

ActiveSupport::TestCase.include(OutOfScopeRatings)
