# frozen_string_literal: true

# Handles commands for the Framework aggregate.
#
# Loads the aggregate via the repository, executes the command,
# and stores resulting events.
#
class Frameworks::CommandHandler
  # @param repository [Frameworks::Repository]
  def initialize(repository: Frameworks::Repository.new)
    @repository = repository
  end

  # Creates a new framework.
  #
  # When `created_by` is provided, the creator is automatically assigned
  # as the framework owner collaborator.
  #
  # @param framework_id [String] UUID for the new framework
  # @param name [String] display name
  # @param created_by [String, nil] person_id of the creator (auto-assigned as owner)
  def create_framework(framework_id, name, created_by: nil)
    @repository.with_framework(framework_id) do |framework|
      framework.create(framework_id, name)
      if created_by
        framework.add_collaborator(framework_id, created_by, "owner",
                                   scope_type: nil, scope_id: nil, added_by: created_by)
      end
    end
  end

  # Adds a role family to a framework.
  #
  # @param framework_id [String] UUID of the framework
  # @param role_family_id [String] UUID for the new role family
  # @param name [String] display name
  # @param description [String, nil] optional description
  def add_role_family(framework_id, role_family_id, name, description: nil)
    @repository.with_framework(framework_id) do |framework|
      framework.add_role_family(framework_id, role_family_id, name, description: description)
    end
  end

  # Updates a role family.
  #
  # @param framework_id [String] UUID of the framework
  # @param role_family_id [String] UUID of the role family
  # @param name [String, nil] updated name
  # @param description [String, nil] updated description
  def update_role_family(framework_id, role_family_id, name: nil, description: nil)
    @repository.with_framework(framework_id) do |framework|
      framework.update_role_family(framework_id, role_family_id, name: name, description: description)
    end
  end

  # Adds a role to a role family.
  #
  # @param framework_id [String] UUID of the framework
  # @param role_id [String] UUID for the new role
  # @param role_family_id [String] UUID of the parent role family
  # @param name [String] display name
  # @param code [String] short code
  # @param track [String] "ic" or "management"
  def add_role(framework_id, role_id, role_family_id, name, code, track)
    @repository.with_framework(framework_id) do |framework|
      framework.add_role(framework_id, role_id, role_family_id, name, code, track)
    end
  end

  # Updates a role.
  #
  # @param framework_id [String] UUID of the framework
  # @param role_id [String] UUID of the role
  # @param name [String, nil] updated name
  # @param code [String, nil] updated code
  # @param track [String, nil] updated track
  def update_role(framework_id, role_id, name: nil, code: nil, track: nil)
    @repository.with_framework(framework_id) do |framework|
      framework.update_role(framework_id, role_id, name: name, code: code, track: track)
    end
  end

  # Adds a level to a role.
  #
  # @param framework_id [String] UUID of the framework
  # @param level_id [String] UUID for the new level
  # @param role_id [String] UUID of the parent role
  # @param ordinal [Integer] seniority ordinal
  # @param title [String] display title
  # @param code [String] short code
  # @param is_entry [Boolean] whether this is an entry-level position
  def add_level(framework_id, level_id, role_id, ordinal, title, code, is_entry: false)
    @repository.with_framework(framework_id) do |framework|
      framework.add_level(framework_id, level_id, role_id, ordinal, title, code, is_entry: is_entry)
    end
  end

  # Updates a level's editorial details (title/code/is_entry). Shape-preserving
  # — applies live regardless of draft state. For ordinal changes, use
  # change_level_ordinal.
  #
  # @param framework_id [String] UUID of the framework
  # @param level_id [String] UUID of the level
  # @param title [String, nil] updated title
  # @param code [String, nil] updated code
  # @param is_entry [Boolean, nil] updated entry-level flag
  def update_level_details(framework_id, level_id, title: nil, code: nil, is_entry: nil)
    @repository.with_framework(framework_id) do |framework|
      framework.update_level_details(framework_id, level_id, title: title, code: code, is_entry: is_entry)
    end
  end

  # Changes a level's ordinal position. Shape-changing — requires a draft
  # because it renumbers rating rows for any in-flight assessment cycle.
  #
  # @param framework_id [String] UUID of the framework
  # @param level_id [String] UUID of the level
  # @param new_ordinal [Integer] the new ordinal position
  # @param reason [String] explanation for the change
  def change_level_ordinal(framework_id, level_id, new_ordinal, reason:)
    @repository.with_framework(framework_id) do |framework|
      framework.change_level_ordinal(framework_id, level_id, new_ordinal, reason: reason)
    end
  end

  # Adds a capability category to a framework.
  #
  # @param framework_id [String] UUID of the framework
  # @param category_id [String] UUID for the new category
  # @param name [String] display name
  # @param description [String, nil] optional description
  # @param ordinal [Integer, nil] display order
  def add_capability_category(framework_id, category_id, name, description: nil, ordinal: nil)
    @repository.with_framework(framework_id) do |framework|
      framework.add_capability_category(framework_id, category_id, name, description: description, ordinal: ordinal)
    end
  end

  # Updates a capability category.
  #
  # @param framework_id [String] UUID of the framework
  # @param category_id [String] UUID of the category
  # @param name [String, nil] updated name
  # @param description [String, nil] updated description
  # @param ordinal [Integer, nil] updated ordinal
  def update_capability_category(framework_id, category_id, name: nil, description: nil, ordinal: nil)
    @repository.with_framework(framework_id) do |framework|
      framework.update_capability_category(framework_id, category_id, name: name, description: description, ordinal: ordinal)
    end
  end

  # Archives a capability category. Shape-changing — requires a draft and
  # an empty category (no active capabilities remaining).
  #
  # @param framework_id [String] UUID of the framework
  # @param category_id [String] UUID of the category
  # @param reason [String] reason for archiving
  def archive_capability_category(framework_id, category_id, reason:)
    @repository.with_framework(framework_id) do |framework|
      framework.archive_capability_category(framework_id, category_id, reason: reason)
    end
  end

  # Updates a capability's name or description.
  #
  # @param framework_id [String] UUID of the framework
  # @param capability_id [String] UUID of the capability
  # @param name [String, nil] updated name
  # @param description [String, nil] updated description
  def update_capability(framework_id, capability_id, name: nil, description: nil)
    @repository.with_framework(framework_id) do |framework|
      framework.update_capability(framework_id, capability_id, name: name, description: description)
    end
  end

  # Adds a capability to a category.
  #
  # @param framework_id [String] UUID of the framework
  # @param capability_id [String] UUID for the new capability
  # @param stable_id [String] UUID linking this concept across versions
  # @param category_id [String] UUID of the parent category
  # @param name [String] display name
  # @param description [String, nil] optional description
  def add_capability(framework_id, capability_id, stable_id, category_id, name, description: nil)
    @repository.with_framework(framework_id) do |framework|
      framework.add_capability(framework_id, capability_id, stable_id, category_id, name, description: description)
    end
  end

  # Archives a capability.
  #
  # @param framework_id [String] UUID of the framework
  # @param capability_id [String] UUID of the capability
  # @param reason [String] reason for archiving
  def archive_capability(framework_id, capability_id, reason:)
    @repository.with_framework(framework_id) do |framework|
      framework.archive_capability(framework_id, capability_id, reason: reason)
    end
  end

  # Creates a capability-role binding.
  #
  # @param framework_id [String] UUID of the framework
  # @param binding_id [String] UUID for the new binding
  # @param capability_id [String] UUID of the capability
  # @param role_id [String] UUID of the role
  # @param weight [BigDecimal] relative weight
  # @param requirement_type [String] "must_have" or "flexible"
  def create_capability_role_binding(framework_id, binding_id, capability_id, role_id, weight: 1.0, individual_tolerance: nil)
    @repository.with_framework(framework_id) do |framework|
      framework.create_capability_role_binding(framework_id, binding_id, capability_id, role_id, weight: weight, individual_tolerance: individual_tolerance)
    end
  end

  # Updates a capability-role binding.
  #
  # @param framework_id [String] UUID of the framework
  # @param binding_id [String] UUID of the binding
  # @param weight [BigDecimal, nil] updated weight
  # @param individual_tolerance [BigDecimal, nil] updated tolerance
  def update_capability_role_binding(framework_id, binding_id, weight: nil, individual_tolerance: nil)
    @repository.with_framework(framework_id) do |framework|
      framework.update_capability_role_binding(framework_id, binding_id, weight: weight, individual_tolerance: individual_tolerance)
    end
  end

  # Removes a capability-role binding.
  #
  # @param framework_id [String] UUID of the framework
  # @param binding_id [String] UUID of the binding
  def remove_capability_role_binding(framework_id, binding_id)
    @repository.with_framework(framework_id) do |framework|
      framework.remove_capability_role_binding(framework_id, binding_id)
    end
  end

  # Sets a behavioural expectation.
  #
  # @param framework_id [String] UUID of the framework
  # @param expectation_id [String] UUID for the expectation
  # @param stable_id [String] UUID linking this concept across versions
  # @param capability_id [String] UUID of the parent capability
  # @param level_ordinal [Integer] seniority level ordinal
  # @param description [String] the expectation description
  def set_behavioural_expectation(framework_id, expectation_id, stable_id, capability_id, level_ordinal, description)
    @repository.with_framework(framework_id) do |framework|
      framework.set_behavioural_expectation(framework_id, expectation_id, stable_id, capability_id, level_ordinal, description)
    end
  end

  # Updates a behavioural expectation.
  #
  # @param framework_id [String] UUID of the framework
  # @param expectation_id [String] UUID of the expectation
  # @param new_description [String] the updated description
  # @param rationale [String] reason for the change
  def update_behavioural_expectation(framework_id, expectation_id, new_description, rationale:)
    @repository.with_framework(framework_id) do |framework|
      framework.update_behavioural_expectation(framework_id, expectation_id, new_description, rationale: rationale)
    end
  end

  # Adds a role illustration.
  #
  # @param framework_id [String] UUID of the framework
  # @param illustration_id [String] UUID for the new illustration
  # @param stable_id [String] UUID linking this concept across versions
  # @param expectation_id [String] UUID of the parent expectation
  # @param role_id [String] UUID of the role
  # @param ordinal [Integer] display order
  # @param description [String] the illustration text
  def add_role_illustration(framework_id, illustration_id, stable_id, expectation_id, role_id, ordinal, description)
    @repository.with_framework(framework_id) do |framework|
      framework.add_role_illustration(framework_id, illustration_id, stable_id, expectation_id, role_id, ordinal, description)
    end
  end

  # Updates a role illustration.
  #
  # @param framework_id [String] UUID of the framework
  # @param illustration_id [String] UUID of the illustration
  # @param new_description [String] the updated description
  # @param rationale [String] reason for the change
  def update_role_illustration(framework_id, illustration_id, new_description, rationale:)
    @repository.with_framework(framework_id) do |framework|
      framework.update_role_illustration(framework_id, illustration_id, new_description, rationale: rationale)
    end
  end

  # Removes a role illustration.
  #
  # @param framework_id [String] UUID of the framework
  # @param illustration_id [String] UUID of the illustration
  # @param reason [String] reason for removal
  def remove_role_illustration(framework_id, illustration_id, reason:)
    @repository.with_framework(framework_id) do |framework|
      framework.remove_role_illustration(framework_id, illustration_id, reason: reason)
    end
  end

  # Reorders illustrations for an expectation and role.
  #
  # @param framework_id [String] UUID of the framework
  # @param expectation_id [String] UUID of the expectation
  # @param role_id [String] UUID of the role
  # @param new_ordering [Array<String>] ordered list of illustration_ids
  def reorder_role_illustrations(framework_id, expectation_id, role_id, new_ordering)
    @repository.with_framework(framework_id) do |framework|
      framework.reorder_role_illustrations(framework_id, expectation_id, role_id, new_ordering)
    end
  end

  # ── Collaborator commands ──

  # Adds a collaborator to a framework.
  #
  # @param framework_id [String] UUID of the framework
  # @param person_id [String] UUID of the person
  # @param collaborator_role [String] one of the 8 collaborator roles
  # @param scope_type [String, nil] nil for framework-wide, or entity type
  # @param scope_id [String, nil] UUID of the scoped entity
  # @param added_by [String] person_id of who added the collaborator
  def add_collaborator(framework_id, person_id, collaborator_role, scope_type: nil, scope_id: nil, added_by:)
    @repository.with_framework(framework_id) do |framework|
      framework.add_collaborator(framework_id, person_id, collaborator_role,
                                 scope_type: scope_type, scope_id: scope_id, added_by: added_by)
    end
  end

  # Changes a collaborator's role on a framework.
  #
  # @param framework_id [String] UUID of the framework
  # @param person_id [String] UUID of the collaborator
  # @param old_role [String] the current role being replaced
  # @param new_role [String] the new role
  # @param scope_type [String, nil] nil for framework-wide, or entity type
  # @param scope_id [String, nil] UUID of the scoped entity
  # @param changed_by [String] person_id of who made the change
  def change_collaborator_role(framework_id, person_id, old_role, new_role, scope_type: nil, scope_id: nil, changed_by:)
    @repository.with_framework(framework_id) do |framework|
      framework.change_collaborator_role(framework_id, person_id, old_role, new_role,
                                         scope_type: scope_type, scope_id: scope_id, changed_by: changed_by)
    end
  end

  # Removes a collaborator from a framework.
  #
  # @param framework_id [String] UUID of the framework
  # @param person_id [String] UUID of the collaborator
  # @param collaborator_role [String] the role being removed
  # @param scope_type [String, nil] nil for framework-wide, or entity type
  # @param scope_id [String, nil] UUID of the scoped entity
  # @param removed_by [String] person_id of who removed the collaborator
  def remove_collaborator(framework_id, person_id, collaborator_role, scope_type: nil, scope_id: nil, removed_by:)
    @repository.with_framework(framework_id) do |framework|
      framework.remove_collaborator(framework_id, person_id, collaborator_role,
                                    scope_type: scope_type, scope_id: scope_id, removed_by: removed_by)
    end
  end

  # ── Suggested edit commands ──

  # Suggests an edit to a framework entity field.
  #
  # Auto-approves if the author has approval authority AND mode is :editing
  # (the default). This means the controller never decides whether to
  # auto-approve — the decision derives from aggregate state.
  #
  # Event trail on auto-approve: EditSuggested + SuggestionApproved + content change (3 events)
  # Event trail on pending:      EditSuggested (1 event)
  #
  # @param framework_id [String] UUID of the framework
  # @param suggestion_id [String] UUID for the new suggestion
  # @param target_entity_type [String] type of entity (e.g. "role_illustration")
  # @param target_entity_id [String] UUID of the entity
  # @param field [String] field being edited (e.g. "description")
  # @param suggested_value [String] the proposed new value
  # @param author_id [String] UUID of the author
  # @param rationale [String, nil] optional explanation
  # @param mode [Symbol] :editing (auto-approve if authority) or :suggesting (always pending)
  def suggest_edit(framework_id, suggestion_id, target_entity_type, target_entity_id,
                   field, suggested_value, author_id, rationale: nil, mode: :editing)
    @repository.with_framework(framework_id) do |framework|
      framework.suggest_edit(framework_id, suggestion_id, target_entity_type, target_entity_id,
                             field, suggested_value, author_id, rationale: rationale)

      if mode == :editing && framework.can_approve?(author_id, target_entity_type: target_entity_type)
        framework.approve_suggestion(suggestion_id, author_id, comment: "Auto-approved")
      end
    end
  end

  # Suggests creating a new framework entity. The target entity does not yet
  # exist; proposed_attributes carries the data needed to construct it on
  # approval.
  #
  # Auto-approves if the author has approval authority AND mode is :editing
  # (the default), mirroring the suggest_edit pattern.
  #
  # Event trail on auto-approve: EntityCreationSuggested + SuggestionApproved + add_* event(s)
  # Event trail on pending:      EntityCreationSuggested
  #
  # @param framework_id [String] UUID of the framework
  # @param suggestion_id [String] UUID for the new suggestion
  # @param target_entity_type [String] type of entity to create (e.g. "capability")
  # @param proposed_attributes [Hash] attributes for the new entity
  # @param parent_id [String, nil] UUID of the parent entity, nil for framework-level entities
  # @param author_id [String] UUID of the author
  # @param rationale [String, nil] optional explanation
  # @param mode [Symbol] :editing (auto-approve if authority) or :suggesting (always pending)
  # @return [String, nil] the created entity ID when auto-approved, nil when pending
  def suggest_create(framework_id, suggestion_id, target_entity_type, proposed_attributes,
                     parent_id:, author_id:, rationale: nil, mode: :editing)
    created_entity_id = nil

    @repository.with_framework(framework_id) do |framework|
      framework.suggest_create(framework_id, suggestion_id, target_entity_type, proposed_attributes,
                               parent_id: parent_id, author_id: author_id, rationale: rationale)

      if mode == :editing && framework.can_approve?(author_id, target_entity_type: target_entity_type)
        created_entity_id = framework.approve_suggestion(suggestion_id, author_id, comment: "Auto-approved")
      end
    end

    created_entity_id
  end

  # Suggests deleting (or archiving) an existing framework entity.
  #
  # Auto-approves if the author has approval authority AND mode is :editing
  # (the default).
  #
  # @param framework_id [String] UUID of the framework
  # @param suggestion_id [String] UUID for the new suggestion
  # @param target_entity_type [String] type of entity (e.g. "capability")
  # @param target_entity_id [String] UUID of the entity to delete
  # @param author_id [String] UUID of the author
  # @param rationale [String, nil] optional explanation
  # @param mode [Symbol] :editing (auto-approve if authority) or :suggesting (always pending)
  def suggest_delete(framework_id, suggestion_id, target_entity_type, target_entity_id,
                     author_id:, rationale: nil, mode: :editing)
    @repository.with_framework(framework_id) do |framework|
      framework.suggest_delete(framework_id, suggestion_id, target_entity_type, target_entity_id,
                               author_id: author_id, rationale: rationale)

      if mode == :editing && framework.can_approve?(author_id, target_entity_type: target_entity_type)
        framework.approve_suggestion(suggestion_id, author_id, comment: "Auto-approved")
      end
    end
  end

  # Amends the author's own pending suggestion.
  #
  # @param framework_id [String] UUID of the framework
  # @param suggestion_id [String] UUID of the suggestion
  # @param new_suggested_value [String] the revised proposed value
  # @param author_id [String] UUID of the author
  # @param rationale [String, nil] updated explanation
  def amend_suggestion(framework_id, suggestion_id, new_suggested_value, author_id, rationale: nil)
    @repository.with_framework(framework_id) do |framework|
      framework.amend_suggestion(suggestion_id, new_suggested_value, author_id, rationale: rationale)
    end
  end

  # Approves a pending suggestion, applies the content change, and auto-rejects
  # any competing pending suggestions on the same entity field.
  #
  # @param framework_id [String] UUID of the framework
  # @param suggestion_id [String] UUID of the suggestion
  # @param reviewer_id [String] UUID of the reviewer
  # @param comment [String, nil] optional reviewer comment
  def approve_suggestion(framework_id, suggestion_id, reviewer_id, comment: nil)
    @repository.with_framework(framework_id) do |framework|
      framework.approve_suggestion(suggestion_id, reviewer_id, comment: comment)
    end
  end

  # Rejects a pending suggestion.
  #
  # @param framework_id [String] UUID of the framework
  # @param suggestion_id [String] UUID of the suggestion
  # @param reviewer_id [String] UUID of the reviewer
  # @param comment [String, nil] rejection reason
  def reject_suggestion(framework_id, suggestion_id, reviewer_id, comment: nil)
    @repository.with_framework(framework_id) do |framework|
      framework.reject_suggestion(suggestion_id, reviewer_id, comment: comment)
    end
  end

  # Withdraws the author's own pending suggestion.
  #
  # @param framework_id [String] UUID of the framework
  # @param suggestion_id [String] UUID of the suggestion
  # @param author_id [String] UUID of the author (must match the original)
  def withdraw_suggestion(framework_id, suggestion_id, author_id)
    @repository.with_framework(framework_id) do |framework|
      framework.withdraw_suggestion(suggestion_id, author_id)
    end
  end

  # ── Versioning commands ──

  # Starts a draft phase for a new framework version.
  #
  # @param framework_id [String] UUID of the framework
  # @param target_version [Integer] the version number being drafted
  # @param started_by [String] UUID of the user who started the draft
  def start_draft(framework_id, target_version, started_by)
    @repository.with_framework(framework_id) do |framework|
      framework.start_draft(framework_id, target_version, started_by)
    end
  end

  # Defines a migration mapping between versions.
  #
  # @param framework_id [String] UUID of the framework
  # @param mapping_id [String] UUID for this mapping
  # @param from_stable_id [String] stable_id in the current published version
  # @param to_stable_id [String, nil] stable_id in the draft version
  # @param mapping_type [String] one of: same, evolved, split, archived, new
  # @param requires_reassessment [Boolean] whether existing ratings need review
  # @param reason [String, nil] explanation of the mapping
  def define_migration_mapping(framework_id, mapping_id, from_stable_id, to_stable_id, mapping_type,
                               requires_reassessment: false, reason: nil)
    @repository.with_framework(framework_id) do |framework|
      framework.define_migration_mapping(framework_id, mapping_id, from_stable_id, to_stable_id, mapping_type,
                                         requires_reassessment: requires_reassessment, reason: reason)
    end
  end

  # Configures scoring thresholds for a framework.
  #
  # @param framework_id [String] UUID of the framework
  # @param mastery_threshold [BigDecimal, nil] ratio above baseline for mastery
  # @param promotion_score_threshold [BigDecimal, nil] ratio for promotion readiness
  # @param underperforming_threshold [BigDecimal, nil] ratio below which the person
  #   is classified as underperforming (vs progressing)
  # @param overperformance_cap [Integer, nil] levels above assigned that count
  # @param deficit_threshold [BigDecimal, nil] weighted deficit blocking threshold
  def configure_scoring_thresholds(framework_id, mastery_threshold: nil, promotion_score_threshold: nil,
                                   underperforming_threshold: nil,
                                   overperformance_cap: nil, deficit_threshold: nil)
    @repository.with_framework(framework_id) do |framework|
      framework.configure_scoring_thresholds(
        framework_id,
        mastery_threshold: mastery_threshold,
        promotion_score_threshold: promotion_score_threshold,
        underperforming_threshold: underperforming_threshold,
        overperformance_cap: overperformance_cap,
        deficit_threshold: deficit_threshold
      )
    end
  end

  # Publishes the current draft as a new framework version.
  #
  # @param framework_id [String] UUID of the framework
  # @param published_by [String] UUID of the user who published
  def publish_version(framework_id, published_by)
    @repository.with_framework(framework_id) do |framework|
      framework.publish_version(framework_id, published_by)
    end
  end
end
