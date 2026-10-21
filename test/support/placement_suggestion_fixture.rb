# frozen_string_literal: true

# One framework and three people for the placement-suggestion tests: Alex, an
# E3 engineer whose feedback is being placed; Morgan, Alex's manager; and
# Jordan, a peer who gave the feedback. The SWE role reads two capabilities
# at levels 2–4; a capability bound only to another role and a level-5 cell
# sit outside the candidate window, so a test can prove they never appear.
module PlacementSuggestionFixture
  FakeModel = Struct.new(:proposals, :error, :prompts, keyword_init: true) do
    def model = "claude-opus-5-5"

    def suggest(prompt)
      prompts << prompt
      raise error if error

      proposals
    end
  end

  def build_placement_fixture(suggestions_enabled: true)
    @tenant = create(:tenant, evidence_suggestions_enabled: suggestions_enabled)
    @alex_user = create(:user, password: "password123", email: "alex@example.com")
    @morgan_user = create(:user, password: "password123", email: "morgan@example.com")
    @jordan_user = create(:user, password: "password123", email: "jordan@example.com")
    @stranger_user = create(:user, password: "password123", email: "sam@example.com")

    ActsAsTenant.with_tenant(@tenant) do
      @morgan = create(:person, tenant: @tenant, email: @morgan_user.email, name: "Morgan Reid")
      @alex = create(:person, tenant: @tenant, email: @alex_user.email, name: "Alex Chen", manager: @morgan)
      @jordan = create(:person, tenant: @tenant, email: @jordan_user.email, name: "Jordan Lee", manager: @morgan)
      @stranger = create(:person, tenant: @tenant, email: @stranger_user.email, name: "Sam Stone")
      @alex_tu = create(:tenant_user, tenant: @tenant, user: @alex_user, person: @alex, role: :member)
      @morgan_tu = create(:tenant_user, tenant: @tenant, user: @morgan_user, person: @morgan, role: :member)
      @jordan_tu = create(:tenant_user, tenant: @tenant, user: @jordan_user, person: @jordan, role: :member)
      @stranger_tu = create(:tenant_user, tenant: @tenant, user: @stranger_user, person: @stranger, role: :member)

      @framework_id = SecureRandom.uuid_v7
      create(:framework_state, framework_id: @framework_id, name: "Eng")
      family = create(:framework_role_family, framework_id: @framework_id, name: "Eng")
      @role = create(:framework_role, role_family_id: family.role_family_id, name: "Software Engineer", code: "E", track: "ic")
      levels = (2..5).to_h do |ordinal|
        [ ordinal, create(:framework_level, role_id: @role.role_id, ordinal: ordinal, title: "Engineer #{ordinal}", code: "E#{ordinal}") ]
      end
      other_role = create(:framework_role, role_family_id: family.role_family_id, name: "Designer", code: "D", track: "ic")
      category = create(:framework_capability_category, framework_id: @framework_id, name: "Delivery", ordinal: 1)

      @ownership = bound_capability(category, "Ownership", "Sees work through.", (2..5))
      @collaboration = bound_capability(category, "Collaboration", "Works well with others.", (2..4))
      @design_craft = create(:framework_capability, category_id: category.category_id, name: "Design craft")
      create(:framework_capability_role_binding, capability_id: @design_craft.capability_id, role_id: other_role.role_id, weight: 1.0)
      create(:framework_behavioural_expectation, capability_id: @design_craft.capability_id, level_ordinal: 3, description: "Crafts.")

      PersonDevelopment::CommandHandler.new.assign_to_framework(@alex.id, @framework_id, @role.role_id, levels[3].level_id)
      @assignment = PersonFrameworkAssignment.find_by(person_id: @alex.id, framework_id: @framework_id)
    end
  end

  # Feedback from Jordan on Alex, recorded through the real command handler.
  #
  # @return [EvidenceItem]
  def record_peer_feedback(content: "Alex owned the outage follow-up end to end and kept everyone informed.",
                           placed_on: nil)
    evidence_id = SecureRandom.uuid_v7
    cell = placed_on ? { capability_stable_id: placed_on.stable_id, level_ordinal: 3, valence: "demonstrated" } : {}
    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.record_evidence(@alex.id, @framework_id, evidence_id,
        source: "peer", evidence_type: "peer_feedback", content: content, author_id: @jordan.id, **cell)
      EvidenceItem.find(evidence_id)
    end
  end

  def proposal(capability, level_ordinal: 3, valence: "demonstrated", confidence: 0.8,
               rationale: "“owned the outage follow-up end to end” shows ownership.")
    Evidence::SuggestionModel::Proposal.new(capability_stable_id: capability.stable_id, level_ordinal: level_ordinal,
                                            valence: valence, confidence: confidence, rationale: rationale)
  end

  # Runs the block with the model stubbed and an API key present.
  #
  # @return [FakeModel]
  def with_fake_suggestion_model(proposals: [], error: nil)
    fake = FakeModel.new(proposals: proposals, error: error, prompts: [])
    Evidence::SuggestionModel.stub(:configured?, true) do
      Evidence::SuggestionModel.stub(:new, ->(**) { fake }) { yield fake }
    end
    fake
  end

  def context_for(person)
    tenant_user = ActsAsTenant.with_tenant(@tenant) { TenantUser.find_by(person_id: person.id) }
    AuthorizationContext.new(user: tenant_user.user, tenant_user: tenant_user, person: person)
  end

  private

  def bound_capability(category, name, description, ordinals)
    capability = create(:framework_capability, category_id: category.category_id, name: name, description: description)
    create(:framework_capability_role_binding, capability_id: capability.capability_id, role_id: @role.role_id, weight: 1.0)
    ordinals.each do |ordinal|
      expectation = create(:framework_behavioural_expectation, capability_id: capability.capability_id,
        level_ordinal: ordinal, description: "#{name} at #{ordinal}")
      create(:framework_role_illustration, expectation_id: expectation.expectation_id, role_id: @role.role_id,
        ordinal: 1, description: "#{name} example at #{ordinal}")
    end
    capability
  end
end
