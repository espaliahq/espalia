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
  # @param framework_id [String] UUID for the new framework
  # @param name [String] display name
  def create_framework(framework_id, name)
    @repository.with_framework(framework_id) do |framework|
      framework.create(framework_id, name)
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

  # Updates a level.
  #
  # @param framework_id [String] UUID of the framework
  # @param level_id [String] UUID of the level
  # @param ordinal [Integer, nil] updated ordinal
  # @param title [String, nil] updated title
  # @param code [String, nil] updated code
  def update_level(framework_id, level_id, ordinal: nil, title: nil, code: nil)
    @repository.with_framework(framework_id) do |framework|
      framework.update_level(framework_id, level_id, ordinal: ordinal, title: title, code: code)
    end
  end

  # Adds a capability category to a framework.
  #
  # @param framework_id [String] UUID of the framework
  # @param category_id [String] UUID for the new category
  # @param name [String] display name
  # @param description [String, nil] optional description
  # @param ordinal [Integer, nil] display order
  def add_capability_category(framework_id, category_id, name, description: nil, ordinal: nil, category_tolerance: nil)
    @repository.with_framework(framework_id) do |framework|
      framework.add_capability_category(framework_id, category_id, name, description: description, ordinal: ordinal, category_tolerance: category_tolerance)
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

      if mode == :editing && framework.can_approve?(author_id)
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
  def withdraw_suggestion(framework_id, suggestion_id)
    @repository.with_framework(framework_id) do |framework|
      framework.withdraw_suggestion(suggestion_id)
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
