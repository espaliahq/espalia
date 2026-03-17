# frozen_string_literal: true

# Event-sourced aggregate for a career framework.
#
# One RES stream per framework: tenant-{tenant_id}/Framework-{framework_id}.
# Command methods validate invariants and apply events.
# Event handler methods (on blocks) update internal state.
#
class Frameworks::Aggregate
  include AggregateRoot

  def initialize
    @name = nil
    @status = :new
    @role_families = {}
    @roles = {}
    @levels = {}
    @capability_categories = {}
    @capabilities = {}
    @expectations = {}
    @illustrations = {}
    @bindings = {}
    @collaborators = {}
    @pending_edits = {}
    @current_version = 0
    @draft_in_progress = false
  end

  # Creates a new framework.
  #
  # @param framework_id [String] UUID for the framework
  # @param name [String] display name
  # @raise [RuntimeError] if the framework has already been created
  def create(framework_id, name)
    raise "Framework already created" unless @status == :new

    apply(Frameworks::Events::FrameworkCreated.new(data: {
      framework_id: framework_id,
      name: name
    }))
  end

  # Adds a role family to the framework.
  #
  # @param framework_id [String] UUID of the framework
  # @param role_family_id [String] UUID for the new role family
  # @param name [String] display name
  # @param description [String, nil] optional description
  # @raise [RuntimeError] if framework not created or role family already exists
  def add_role_family(framework_id, role_family_id, name, description: nil)
    ensure_created!
    raise "Role family #{role_family_id} already exists" if @role_families.key?(role_family_id)

    apply(Frameworks::Events::RoleFamilyAdded.new(data: {
      framework_id: framework_id,
      role_family_id: role_family_id,
      name: name,
      description: description
    }))
  end

  # Updates a role family.
  #
  # @param framework_id [String] UUID of the framework
  # @param role_family_id [String] UUID of the role family
  # @param name [String, nil] updated name
  # @param description [String, nil] updated description
  # @raise [RuntimeError] if role family does not exist
  def update_role_family(framework_id, role_family_id, name: nil, description: nil)
    ensure_created!
    raise "Role family #{role_family_id} not found" unless @role_families.key?(role_family_id)

    apply(Frameworks::Events::RoleFamilyUpdated.new(data: {
      framework_id: framework_id,
      role_family_id: role_family_id,
      name: name,
      description: description
    }.compact))
  end

  # Adds a role to a role family.
  #
  # @param framework_id [String] UUID of the framework
  # @param role_id [String] UUID for the new role
  # @param role_family_id [String] UUID of the parent role family
  # @param name [String] display name
  # @param code [String] short code (e.g. "E", "EM")
  # @param track [String] "ic" or "management"
  # @raise [RuntimeError] if role family not found or role already exists
  def add_role(framework_id, role_id, role_family_id, name, code, track)
    ensure_created!
    raise "Role family #{role_family_id} not found" unless @role_families.key?(role_family_id)
    raise "Role #{role_id} already exists" if @roles.key?(role_id)

    apply(Frameworks::Events::RoleAdded.new(data: {
      framework_id: framework_id,
      role_id: role_id,
      role_family_id: role_family_id,
      name: name,
      code: code,
      track: track
    }))
  end

  # Updates a role.
  #
  # @param framework_id [String] UUID of the framework
  # @param role_id [String] UUID of the role
  # @param name [String, nil] updated name
  # @param code [String, nil] updated code
  # @param track [String, nil] updated track
  # @raise [RuntimeError] if role does not exist
  def update_role(framework_id, role_id, name: nil, code: nil, track: nil)
    ensure_created!
    raise "Role #{role_id} not found" unless @roles.key?(role_id)

    apply(Frameworks::Events::RoleUpdated.new(data: {
      framework_id: framework_id,
      role_id: role_id,
      name: name,
      code: code,
      track: track
    }.compact))
  end

  # Adds a level to a role.
  #
  # @param framework_id [String] UUID of the framework
  # @param level_id [String] UUID for the new level
  # @param role_id [String] UUID of the parent role
  # @param ordinal [Integer] seniority ordinal
  # @param title [String] display title
  # @param code [String] short code (e.g. "E3")
  # @param is_entry [Boolean] whether this is an entry-level position
  # @raise [RuntimeError] if role not found or level already exists
  def add_level(framework_id, level_id, role_id, ordinal, title, code, is_entry: false)
    ensure_created!
    raise "Role #{role_id} not found" unless @roles.key?(role_id)
    raise "Level #{level_id} already exists" if @levels.key?(level_id)

    apply(Frameworks::Events::LevelAdded.new(data: {
      framework_id: framework_id,
      level_id: level_id,
      role_id: role_id,
      ordinal: ordinal,
      title: title,
      code: code,
      is_entry: is_entry
    }))
  end

  # Updates a level.
  #
  # @param framework_id [String] UUID of the framework
  # @param level_id [String] UUID of the level
  # @param ordinal [Integer, nil] updated ordinal
  # @param title [String, nil] updated title
  # @param code [String, nil] updated code
  # @raise [RuntimeError] if level does not exist
  def update_level(framework_id, level_id, ordinal: nil, title: nil, code: nil)
    ensure_created!
    raise "Level #{level_id} not found" unless @levels.key?(level_id)

    apply(Frameworks::Events::LevelUpdated.new(data: {
      framework_id: framework_id,
      level_id: level_id,
      ordinal: ordinal,
      title: title,
      code: code
    }.compact))
  end

  # Adds a capability category to the framework.
  #
  # @param framework_id [String] UUID of the framework
  # @param category_id [String] UUID for the new category
  # @param name [String] display name
  # @param description [String, nil] optional description
  # @param ordinal [Integer, nil] display order
  # @param category_tolerance [BigDecimal, nil] nil = uncapped, 0 = must balance,
  #   N = absorbs up to N weighted points of deficit
  # @raise [RuntimeError] if category already exists
  def add_capability_category(framework_id, category_id, name, description: nil, ordinal: nil, category_tolerance: nil)
    ensure_created!
    raise "Category #{category_id} already exists" if @capability_categories.key?(category_id)

    apply(Frameworks::Events::CapabilityCategoryAdded.new(data: {
      framework_id: framework_id,
      category_id: category_id,
      name: name,
      description: description,
      ordinal: ordinal,
      category_tolerance: category_tolerance
    }))
  end

  # Sets the tolerance for a capability category.
  #
  # @param framework_id [String] UUID of the framework
  # @param category_id [String] UUID of the category
  # @param category_tolerance [BigDecimal, nil] nil = uncapped, 0 = must balance,
  #   N = absorbs up to N weighted points of deficit
  # @raise [RuntimeError] if category does not exist
  def set_category_tolerance(framework_id, category_id, category_tolerance)
    ensure_created!
    raise "Category #{category_id} not found" unless @capability_categories.key?(category_id)

    apply(Frameworks::Events::CategoryToleranceSet.new(data: {
      framework_id: framework_id,
      category_id: category_id,
      category_tolerance: category_tolerance
    }))
  end

  # Updates a capability category.
  #
  # @param framework_id [String] UUID of the framework
  # @param category_id [String] UUID of the category
  # @param name [String, nil] updated name
  # @param description [String, nil] updated description
  # @param ordinal [Integer, nil] updated ordinal
  # @raise [RuntimeError] if category does not exist
  def update_capability_category(framework_id, category_id, name: nil, description: nil, ordinal: nil)
    ensure_created!
    raise "Category #{category_id} not found" unless @capability_categories.key?(category_id)

    apply(Frameworks::Events::CapabilityCategoryUpdated.new(data: {
      framework_id: framework_id,
      category_id: category_id,
      name: name,
      description: description,
      ordinal: ordinal
    }.compact))
  end

  # Adds a capability to a category.
  #
  # @param framework_id [String] UUID of the framework
  # @param capability_id [String] UUID for the new capability
  # @param stable_id [String] UUID linking this concept across versions
  # @param category_id [String] UUID of the parent category
  # @param name [String] display name
  # @param description [String, nil] optional description
  # @raise [RuntimeError] if category not found or capability already exists
  def add_capability(framework_id, capability_id, stable_id, category_id, name, description: nil)
    ensure_created!
    raise "Category #{category_id} not found" unless @capability_categories.key?(category_id)
    raise "Capability #{capability_id} already exists" if @capabilities.key?(capability_id)

    apply(Frameworks::Events::CapabilityAdded.new(data: {
      framework_id: framework_id,
      capability_id: capability_id,
      stable_id: stable_id,
      category_id: category_id,
      name: name,
      description: description
    }))
  end

  # Archives a capability.
  #
  # @param framework_id [String] UUID of the framework
  # @param capability_id [String] UUID of the capability
  # @param reason [String] reason for archiving
  # @raise [RuntimeError] if capability not found or already archived
  def archive_capability(framework_id, capability_id, reason:)
    ensure_created!
    raise "Capability #{capability_id} not found" unless @capabilities.key?(capability_id)
    raise "Capability #{capability_id} already archived" if @capabilities[capability_id][:status] == :archived

    apply(Frameworks::Events::CapabilityArchived.new(data: {
      framework_id: framework_id,
      capability_id: capability_id,
      reason: reason
    }))
  end

  # Creates a capability-role binding.
  #
  # @param framework_id [String] UUID of the framework
  # @param binding_id [String] UUID for the new binding
  # @param capability_id [String] UUID of the capability
  # @param role_id [String] UUID of the role
  # @param weight [BigDecimal] relative weight (default 1.0)
  # @param individual_tolerance [BigDecimal, nil] nil = category-governed,
  #   0 = mandatory, N = deficit capped at N before entering category pool
  # @raise [RuntimeError] if capability or role not found, or binding already exists
  def create_capability_role_binding(framework_id, binding_id, capability_id, role_id, weight: 1.0, individual_tolerance: nil)
    ensure_created!
    raise "Capability #{capability_id} not found" unless @capabilities.key?(capability_id)
    raise "Role #{role_id} not found" unless @roles.key?(role_id)
    raise "Binding #{binding_id} already exists" if @bindings.key?(binding_id)

    apply(Frameworks::Events::CapabilityRoleBindingCreated.new(data: {
      framework_id: framework_id,
      binding_id: binding_id,
      capability_id: capability_id,
      role_id: role_id,
      weight: weight,
      individual_tolerance: individual_tolerance
    }))
  end

  # Updates a capability-role binding.
  #
  # @param framework_id [String] UUID of the framework
  # @param binding_id [String] UUID of the binding
  # @param weight [BigDecimal, nil] updated weight
  # @param individual_tolerance [BigDecimal, nil] updated individual tolerance
  # @raise [RuntimeError] if binding does not exist
  def update_capability_role_binding(framework_id, binding_id, weight: nil, individual_tolerance: nil)
    ensure_created!
    raise "Binding #{binding_id} not found" unless @bindings.key?(binding_id)

    apply(Frameworks::Events::CapabilityRoleBindingUpdated.new(data: {
      framework_id: framework_id,
      binding_id: binding_id,
      weight: weight,
      individual_tolerance: individual_tolerance
    }.compact))
  end

  # Removes a capability-role binding.
  #
  # @param framework_id [String] UUID of the framework
  # @param binding_id [String] UUID of the binding
  # @raise [RuntimeError] if binding does not exist
  def remove_capability_role_binding(framework_id, binding_id)
    ensure_created!
    raise "Binding #{binding_id} not found" unless @bindings.key?(binding_id)

    apply(Frameworks::Events::CapabilityRoleBindingRemoved.new(data: {
      framework_id: framework_id,
      binding_id: binding_id
    }))
  end

  # Sets a behavioural expectation for a capability at a level ordinal.
  #
  # @param framework_id [String] UUID of the framework
  # @param expectation_id [String] UUID for the expectation
  # @param stable_id [String] UUID linking this concept across versions
  # @param capability_id [String] UUID of the parent capability
  # @param level_ordinal [Integer] seniority level ordinal
  # @param description [String] the expectation description
  # @raise [RuntimeError] if capability not found or expectation already exists
  def set_behavioural_expectation(framework_id, expectation_id, stable_id, capability_id, level_ordinal, description)
    ensure_created!
    raise "Capability #{capability_id} not found" unless @capabilities.key?(capability_id)
    raise "Expectation #{expectation_id} already exists" if @expectations.key?(expectation_id)

    apply(Frameworks::Events::BehaviouralExpectationSet.new(data: {
      framework_id: framework_id,
      expectation_id: expectation_id,
      stable_id: stable_id,
      capability_id: capability_id,
      level_ordinal: level_ordinal,
      description: description
    }))
  end

  # Updates a behavioural expectation description.
  #
  # @param framework_id [String] UUID of the framework
  # @param expectation_id [String] UUID of the expectation
  # @param new_description [String] the updated description
  # @param rationale [String] reason for the change
  # @raise [RuntimeError] if expectation does not exist
  def update_behavioural_expectation(framework_id, expectation_id, new_description, rationale:)
    ensure_created!
    raise "Expectation #{expectation_id} not found" unless @expectations.key?(expectation_id)

    apply(Frameworks::Events::BehaviouralExpectationUpdated.new(data: {
      framework_id: framework_id,
      expectation_id: expectation_id,
      new_description: new_description,
      rationale: rationale
    }))
  end

  # Adds a role illustration to an expectation.
  #
  # @param framework_id [String] UUID of the framework
  # @param illustration_id [String] UUID for the new illustration
  # @param stable_id [String] UUID linking this concept across versions
  # @param expectation_id [String] UUID of the parent expectation
  # @param role_id [String] UUID of the role this illustrates for
  # @param ordinal [Integer] display order
  # @param description [String] the illustration text
  # @raise [RuntimeError] if expectation or role not found
  def add_role_illustration(framework_id, illustration_id, stable_id, expectation_id, role_id, ordinal, description)
    ensure_created!
    raise "Expectation #{expectation_id} not found" unless @expectations.key?(expectation_id)
    raise "Role #{role_id} not found" unless @roles.key?(role_id)
    raise "Illustration #{illustration_id} already exists" if @illustrations.key?(illustration_id)

    apply(Frameworks::Events::RoleIllustrationAdded.new(data: {
      framework_id: framework_id,
      illustration_id: illustration_id,
      stable_id: stable_id,
      expectation_id: expectation_id,
      role_id: role_id,
      ordinal: ordinal,
      description: description
    }))
  end

  # Updates a role illustration description.
  #
  # @param framework_id [String] UUID of the framework
  # @param illustration_id [String] UUID of the illustration
  # @param new_description [String] the updated description
  # @param rationale [String] reason for the change
  # @raise [RuntimeError] if illustration does not exist
  def update_role_illustration(framework_id, illustration_id, new_description, rationale:)
    ensure_created!
    raise "Illustration #{illustration_id} not found" unless @illustrations.key?(illustration_id)

    apply(Frameworks::Events::RoleIllustrationUpdated.new(data: {
      framework_id: framework_id,
      illustration_id: illustration_id,
      new_description: new_description,
      rationale: rationale
    }))
  end

  # Removes a role illustration.
  #
  # @param framework_id [String] UUID of the framework
  # @param illustration_id [String] UUID of the illustration
  # @param reason [String] reason for removal
  # @raise [RuntimeError] if illustration does not exist
  def remove_role_illustration(framework_id, illustration_id, reason:)
    ensure_created!
    raise "Illustration #{illustration_id} not found" unless @illustrations.key?(illustration_id)

    apply(Frameworks::Events::RoleIllustrationRemoved.new(data: {
      framework_id: framework_id,
      illustration_id: illustration_id,
      reason: reason
    }))
  end

  # Reorders illustrations for an expectation and role.
  #
  # @param framework_id [String] UUID of the framework
  # @param expectation_id [String] UUID of the expectation
  # @param role_id [String] UUID of the role
  # @param new_ordering [Array<String>] ordered list of illustration_ids
  # @raise [RuntimeError] if expectation or role does not exist
  def reorder_role_illustrations(framework_id, expectation_id, role_id, new_ordering)
    ensure_created!
    raise "Expectation #{expectation_id} not found" unless @expectations.key?(expectation_id)
    raise "Role #{role_id} not found" unless @roles.key?(role_id)

    apply(Frameworks::Events::RoleIllustrationReordered.new(data: {
      framework_id: framework_id,
      expectation_id: expectation_id,
      role_id: role_id,
      new_ordering: new_ordering
    }))
  end

  # ── Suggested edit commands ──

  # Returns whether a user has approval authority on this framework.
  #
  # For now all authenticated users are treated as Editors.
  # When the collaborator model is implemented, this will query
  # @collaborators[user_id]&.[](:role) against [:owner, :editor, ...].
  #
  # @param _user_id [String] UUID of the user
  # @return [Boolean]
  def can_approve?(_user_id)
    true
  end

  # Suggests an edit to a framework entity field.
  #
  # @param framework_id [String] UUID of the framework
  # @param suggestion_id [String] UUID for the new suggestion
  # @param target_entity_type [String] type of entity (e.g. "role_illustration")
  # @param target_entity_id [String] UUID of the entity
  # @param field [String] the field being edited (e.g. "description")
  # @param suggested_value [String] the proposed value
  # @param author_id [String] UUID of the user
  # @param rationale [String, nil] optional explanation
  # @raise [RuntimeError] if framework not created, entity not found, or suggestion already exists
  def suggest_edit(framework_id, suggestion_id, target_entity_type, target_entity_id,
                   field, suggested_value, author_id, rationale: nil)
    ensure_created!
    raise "Suggestion #{suggestion_id} already exists" if @pending_edits.key?(suggestion_id)
    raise_unless_entity_exists!(target_entity_type, target_entity_id)

    apply(Frameworks::Events::EditSuggested.new(data: {
      framework_id: framework_id,
      suggestion_id: suggestion_id,
      target_entity_type: target_entity_type,
      target_entity_id: target_entity_id,
      field: field,
      suggested_value: suggested_value,
      author_id: author_id,
      rationale: rationale
    }.compact))
  end

  # Amends the author's own pending suggestion.
  #
  # @param suggestion_id [String] UUID of the suggestion
  # @param new_suggested_value [String] the revised proposed value
  # @param author_id [String] UUID of the author (must match the original)
  # @param rationale [String, nil] updated explanation
  # @raise [RuntimeError] if suggestion not found or author mismatch
  def amend_suggestion(suggestion_id, new_suggested_value, author_id, rationale: nil)
    ensure_created!
    suggestion = @pending_edits[suggestion_id]
    raise "Suggestion #{suggestion_id} not found" unless suggestion
    raise "Only the author can amend their suggestion" unless suggestion[:author_id] == author_id

    apply(Frameworks::Events::SuggestionAmended.new(data: {
      suggestion_id: suggestion_id,
      new_suggested_value: new_suggested_value,
      author_id: author_id,
      rationale: rationale
    }.compact))
  end

  # Approves a pending suggestion, applies the content change, and auto-rejects
  # any competing pending suggestions on the same entity field.
  #
  # @param suggestion_id [String] UUID of the suggestion
  # @param reviewer_id [String] UUID of the reviewer
  # @param comment [String, nil] optional reviewer comment
  # @raise [RuntimeError] if suggestion not found
  def approve_suggestion(suggestion_id, reviewer_id, comment: nil)
    ensure_created!
    suggestion = @pending_edits[suggestion_id]
    raise "Suggestion #{suggestion_id} not found" unless suggestion

    apply(Frameworks::Events::SuggestionApproved.new(data: {
      suggestion_id: suggestion_id,
      reviewer_id: reviewer_id,
      comment: comment
    }.compact))

    apply_suggested_content_change(suggestion)

    # Auto-reject competing pending suggestions on the same field
    @pending_edits.each_value do |competing|
      next if competing[:suggestion_id] == suggestion_id
      next unless competing[:target_entity_id] == suggestion[:target_entity_id]
      next unless competing[:field] == suggestion[:field]

      apply(Frameworks::Events::SuggestionRejected.new(data: {
        suggestion_id: competing[:suggestion_id],
        reviewer_id: reviewer_id,
        comment: "Superseded by approved suggestion"
      }))
    end
  end

  # Rejects a pending suggestion.
  #
  # @param suggestion_id [String] UUID of the suggestion
  # @param reviewer_id [String] UUID of the reviewer
  # @param comment [String, nil] rejection reason
  # @raise [RuntimeError] if suggestion not found
  def reject_suggestion(suggestion_id, reviewer_id, comment: nil)
    ensure_created!
    raise "Suggestion #{suggestion_id} not found" unless @pending_edits.key?(suggestion_id)

    apply(Frameworks::Events::SuggestionRejected.new(data: {
      suggestion_id: suggestion_id,
      reviewer_id: reviewer_id,
      comment: comment
    }.compact))
  end

  # Withdraws the author's own pending suggestion.
  #
  # @param suggestion_id [String] UUID of the suggestion
  # @raise [RuntimeError] if suggestion not found
  def withdraw_suggestion(suggestion_id)
    ensure_created!
    raise "Suggestion #{suggestion_id} not found" unless @pending_edits.key?(suggestion_id)

    apply(Frameworks::Events::SuggestionWithdrawn.new(data: {
      suggestion_id: suggestion_id
    }))
  end

  # ── Versioning commands ──

  # Configures mastery and promotion readiness scoring thresholds.
  #
  # @param framework_id [String] UUID of the framework
  # @param mastery_threshold [BigDecimal, nil] ratio above baseline for mastery
  # @param promotion_score_threshold [BigDecimal, nil] ratio of next-level baseline
  #   required for promotion readiness score gate
  # @raise [RuntimeError] if framework not created
  def configure_scoring_thresholds(framework_id, mastery_threshold: nil, promotion_score_threshold: nil)
    ensure_created!

    apply(Frameworks::Events::ScoringThresholdsConfigured.new(data: {
      framework_id: framework_id,
      mastery_threshold: mastery_threshold,
      promotion_score_threshold: promotion_score_threshold
    }.compact))
  end

  # Starts a draft phase for a new framework version.
  #
  # Structural events emitted after this will be invisible to the
  # published projection until publish_version is called.
  #
  # @param framework_id [String] UUID of the framework
  # @param target_version [Integer] the version number being drafted
  # @param started_by [String] UUID of the user who started the draft
  # @raise [RuntimeError] if a draft is already in progress
  def start_draft(framework_id, target_version, started_by)
    ensure_created!
    raise "Draft already in progress" if @draft_in_progress
    raise "Target version must be greater than current" unless target_version > @current_version

    apply(Frameworks::Events::DraftVersionStarted.new(data: {
      framework_id: framework_id,
      target_version: target_version,
      started_by: started_by
    }))
  end

  # Defines a migration mapping for a capability between versions.
  #
  # @param framework_id [String] UUID of the framework
  # @param mapping_id [String] UUID for this mapping
  # @param from_stable_id [String] stable_id in the current published version
  # @param to_stable_id [String, nil] stable_id in the draft version
  # @param mapping_type [String] one of: same, evolved, split, archived, new
  # @param requires_reassessment [Boolean] whether existing ratings need review
  # @param reason [String, nil] explanation of the mapping
  # @raise [RuntimeError] if no draft is in progress
  def define_migration_mapping(framework_id, mapping_id, from_stable_id, to_stable_id, mapping_type,
                               requires_reassessment: false, reason: nil)
    ensure_created!
    raise "No draft in progress" unless @draft_in_progress

    apply(Frameworks::Events::MigrationMappingDefined.new(data: {
      framework_id: framework_id,
      mapping_id: mapping_id,
      from_stable_id: from_stable_id,
      to_stable_id: to_stable_id,
      mapping_type: mapping_type,
      requires_reassessment: requires_reassessment,
      reason: reason
    }))
  end

  # Publishes the current draft as a new framework version.
  #
  # The published projection will advance to include all structural
  # events that accumulated during the draft phase.
  #
  # @param framework_id [String] UUID of the framework
  # @param published_by [String] UUID of the user who published
  # @raise [RuntimeError] if no draft is in progress
  def publish_version(framework_id, published_by)
    ensure_created!
    raise "No draft in progress" unless @draft_in_progress

    apply(Frameworks::Events::FrameworkVersionPublished.new(data: {
      framework_id: framework_id,
      version: @draft_version,
      published_by: published_by
    }))
  end

  private

  # @raise [RuntimeError] if the framework has not been created
  def ensure_created!
    raise "Framework not yet created" unless @status == :created
  end

  on Frameworks::Events::FrameworkCreated do |event|
    @framework_id = event.data[:framework_id]
    @name = event.data[:name]
    @status = :created
  end

  on Frameworks::Events::RoleFamilyAdded do |event|
    @role_families[event.data[:role_family_id]] = {
      name: event.data[:name],
      description: event.data[:description]
    }
  end

  on Frameworks::Events::RoleFamilyUpdated do |event|
    family = @role_families[event.data[:role_family_id]]
    family[:name] = event.data[:name] if event.data.key?(:name)
    family[:description] = event.data[:description] if event.data.key?(:description)
  end

  on Frameworks::Events::RoleAdded do |event|
    @roles[event.data[:role_id]] = {
      role_family_id: event.data[:role_family_id],
      name: event.data[:name],
      code: event.data[:code],
      track: event.data[:track]
    }
  end

  on Frameworks::Events::RoleUpdated do |event|
    role = @roles[event.data[:role_id]]
    role[:name] = event.data[:name] if event.data.key?(:name)
    role[:code] = event.data[:code] if event.data.key?(:code)
    role[:track] = event.data[:track] if event.data.key?(:track)
  end

  on Frameworks::Events::LevelAdded do |event|
    @levels[event.data[:level_id]] = {
      role_id: event.data[:role_id],
      ordinal: event.data[:ordinal],
      title: event.data[:title],
      code: event.data[:code]
    }
  end

  on Frameworks::Events::LevelUpdated do |event|
    level = @levels[event.data[:level_id]]
    level[:ordinal] = event.data[:ordinal] if event.data.key?(:ordinal)
    level[:title] = event.data[:title] if event.data.key?(:title)
    level[:code] = event.data[:code] if event.data.key?(:code)
  end

  on Frameworks::Events::CapabilityCategoryAdded do |event|
    @capability_categories[event.data[:category_id]] = {
      name: event.data[:name],
      description: event.data[:description],
      ordinal: event.data[:ordinal],
      category_tolerance: event.data[:category_tolerance]
    }
  end

  on Frameworks::Events::CapabilityCategoryUpdated do |event|
    cat = @capability_categories[event.data[:category_id]]
    cat[:name] = event.data[:name] if event.data.key?(:name)
    cat[:description] = event.data[:description] if event.data.key?(:description)
    cat[:ordinal] = event.data[:ordinal] if event.data.key?(:ordinal)
  end

  on Frameworks::Events::CategoryToleranceSet do |event|
    cat = @capability_categories[event.data[:category_id]]
    cat[:category_tolerance] = event.data[:category_tolerance] if cat
  end

  on Frameworks::Events::CapabilityAdded do |event|
    @capabilities[event.data[:capability_id]] = {
      stable_id: event.data[:stable_id],
      category_id: event.data[:category_id],
      name: event.data[:name],
      status: :active
    }
  end

  on Frameworks::Events::CapabilityArchived do |event|
    @capabilities[event.data[:capability_id]][:status] = :archived
  end

  on Frameworks::Events::CapabilityRoleBindingCreated do |event|
    @bindings[event.data[:binding_id]] = {
      capability_id: event.data[:capability_id],
      role_id: event.data[:role_id],
      weight: event.data[:weight],
      individual_tolerance: event.data[:individual_tolerance]
    }
  end

  on Frameworks::Events::CapabilityRoleBindingUpdated do |event|
    binding = @bindings[event.data[:binding_id]]
    binding[:weight] = event.data[:weight] if event.data.key?(:weight)
    binding[:individual_tolerance] = event.data[:individual_tolerance] if event.data.key?(:individual_tolerance)
  end

  on Frameworks::Events::ScoringThresholdsConfigured do |_event|
    # Thresholds are persisted via projection; no aggregate state needed
  end

  on Frameworks::Events::CapabilityRoleBindingRemoved do |event|
    @bindings.delete(event.data[:binding_id])
  end

  on Frameworks::Events::BehaviouralExpectationSet do |event|
    @expectations[event.data[:expectation_id]] = {
      stable_id: event.data[:stable_id],
      capability_id: event.data[:capability_id],
      level_ordinal: event.data[:level_ordinal]
    }
  end

  on Frameworks::Events::BehaviouralExpectationUpdated do |event|
    # State doesn't track description, only existence
  end

  on Frameworks::Events::RoleIllustrationAdded do |event|
    @illustrations[event.data[:illustration_id]] = {
      stable_id: event.data[:stable_id],
      expectation_id: event.data[:expectation_id],
      role_id: event.data[:role_id],
      ordinal: event.data[:ordinal]
    }
  end

  on Frameworks::Events::RoleIllustrationUpdated do |event|
    # State doesn't track description, only existence
  end

  on Frameworks::Events::RoleIllustrationRemoved do |event|
    @illustrations.delete(event.data[:illustration_id])
  end

  on Frameworks::Events::RoleIllustrationReordered do |event|
    event.data[:new_ordering].each_with_index do |illustration_id, index|
      @illustrations[illustration_id][:ordinal] = index + 1 if @illustrations.key?(illustration_id)
    end
  end

  on Frameworks::Events::DraftVersionStarted do |event|
    @draft_in_progress = true
    @draft_version = event.data[:target_version]
  end

  on Frameworks::Events::FrameworkVersionPublished do |event|
    @current_version = event.data[:version]
    @draft_in_progress = false
    @draft_version = nil
    @migration_mappings = []
  end

  on Frameworks::Events::MigrationMappingDefined do |event|
    @migration_mappings ||= []
    @migration_mappings << event.data[:mapping_id]
  end

  on Frameworks::Events::EditSuggested do |event|
    @pending_edits[event.data[:suggestion_id]] = {
      suggestion_id: event.data[:suggestion_id],
      target_entity_type: event.data[:target_entity_type],
      target_entity_id: event.data[:target_entity_id],
      field: event.data[:field],
      suggested_value: event.data[:suggested_value],
      author_id: event.data[:author_id]
    }
  end

  on Frameworks::Events::SuggestionAmended do |event|
    suggestion = @pending_edits[event.data[:suggestion_id]]
    suggestion[:suggested_value] = event.data[:new_suggested_value] if suggestion
  end

  on Frameworks::Events::SuggestionApproved do |event|
    @pending_edits.delete(event.data[:suggestion_id])
  end

  on Frameworks::Events::SuggestionRejected do |event|
    @pending_edits.delete(event.data[:suggestion_id])
  end

  on Frameworks::Events::SuggestionWithdrawn do |event|
    @pending_edits.delete(event.data[:suggestion_id])
  end

  on Frameworks::Events::SuggestionCommented do |_event|
    # Future: store in comments — no state change needed in aggregate
  end

  # Applies the actual content change event for an approved suggestion.
  #
  # @param suggestion [Hash] pending_edits entry
  # @return [void]
  def apply_suggested_content_change(suggestion)
    case suggestion[:target_entity_type]
    when "role_illustration"
      apply(Frameworks::Events::RoleIllustrationUpdated.new(data: {
        framework_id: @framework_id,
        illustration_id: suggestion[:target_entity_id],
        new_description: suggestion[:suggested_value],
        rationale: "Applied via approved suggestion #{suggestion[:suggestion_id]}"
      }))
    end
  end

  # Raises unless the target entity exists in aggregate state.
  #
  # @param entity_type [String]
  # @param entity_id [String]
  # @raise [RuntimeError] if entity not found
  def raise_unless_entity_exists!(entity_type, entity_id)
    case entity_type
    when "role_illustration"
      raise "Illustration #{entity_id} not found" unless @illustrations.key?(entity_id)
    else
      raise "Unknown entity type: #{entity_type}"
    end
  end
end
