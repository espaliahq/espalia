# frozen_string_literal: true

# Event-sourced aggregate for a career framework.
#
# One RES stream per framework: tenant-{tenant_id}/Framework-{framework_id}.
# Command methods validate invariants and apply events.
# Event handler methods (on blocks) update internal state.
#
class Frameworks::Aggregate
  include AggregateRoot

  # Suggestion target_entity_types whose approval requires a draft because
  # the underlying add_*/archive_* command is shape-changing (alters the
  # (capability_stable_id, level_ordinal) rating grid — see ADR-16).
  SHAPE_CHANGING_CREATE_TYPES = %w[capability behavioural_expectation level].freeze
  SHAPE_CHANGING_DELETE_TYPES = %w[capability].freeze

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
    @draft_version = nil
    @added_during_draft = Set.new
    @archives_needing_mapping = Set.new

    # ── ExplorerGraph projection support ──
    # Native-ID Sets of entities added during the current open draft. The
    # ExplorerGraphBuilder reads these to tag graph nodes with
    # `added_in_draft: true` so view-mode rendering can hide them (matching
    # PublishedState's shape-changing event deferral — see ADR-16).
    # All four are cleared when a draft starts or a version publishes.
    # Distinct from `@added_during_draft` (stable_ids, for archive-mapping).
    @draft_added_level_ids = Set.new
    @draft_added_capability_ids = Set.new
    @draft_added_binding_ids = Set.new
    @draft_added_expectation_ids = Set.new
  end

  # ── ExplorerGraph projection support ──
  # Read-only access to aggregate state for
  # {Frameworks::ExplorerGraphBuilder}. Not part of the aggregate's public
  # command contract — these are intentional projection-side affordances.
  attr_reader :framework_id, :name, :role_families, :roles, :levels,
              :capability_categories, :capabilities, :bindings,
              :expectations, :illustrations, :current_version,
              :draft_in_progress, :draft_version, :added_during_draft,
              :draft_added_level_ids, :draft_added_capability_ids,
              :draft_added_binding_ids, :draft_added_expectation_ids

  # Creates a new framework and opens its bootstrap v1 draft.
  #
  # After create, the aggregate is in a draft for v1. Structural commands
  # (add_capability, add_level, etc.) may be called to populate the initial
  # framework content. Callers must invoke publish_version to produce v1.
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

    # Bootstrap v1 draft so structural commands can populate initial content.
    apply(Frameworks::Events::DraftVersionStarted.new(data: {
      framework_id: framework_id,
      target_version: 1,
      started_by: "system"
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

  # Adds a level to a role. Shape-changing — requires a draft.
  #
  # @param framework_id [String] UUID of the framework
  # @param level_id [String] UUID for the new level
  # @param role_id [String] UUID of the parent role
  # @param ordinal [Integer] seniority ordinal
  # @param title [String] display title
  # @param code [String] short code (e.g. "E3")
  # @param is_entry [Boolean] whether this is an entry-level position
  # @raise [RuntimeError] if no draft in progress, role not found, or level already exists
  def add_level(framework_id, level_id, role_id, ordinal, title, code, is_entry: false)
    ensure_draft_in_progress!
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

  # Updates a level's editorial details (title/code/is_entry). Shape-preserving
  # — applies live regardless of draft state. For ordinal changes, use
  # change_level_ordinal.
  #
  # @param framework_id [String] UUID of the framework
  # @param level_id [String] UUID of the level
  # @param title [String, nil] updated title
  # @param code [String, nil] updated code
  # @param is_entry [Boolean, nil] updated entry-level flag
  # @raise [RuntimeError] if level does not exist
  def update_level_details(framework_id, level_id, title: nil, code: nil, is_entry: nil)
    ensure_created!
    raise "Level #{level_id} not found" unless @levels.key?(level_id)

    apply(Frameworks::Events::LevelUpdated.new(data: {
      framework_id: framework_id,
      level_id: level_id,
      title: title,
      code: code,
      is_entry: is_entry
    }.compact))
  end

  # Changes a level's ordinal position. Shape-changing — requires a draft
  # because it renumbers rating rows for any in-flight assessment cycle.
  #
  # @param framework_id [String] UUID of the framework
  # @param level_id [String] UUID of the level
  # @param new_ordinal [Integer] the new ordinal position
  # @param reason [String] explanation for the change
  # @raise [RuntimeError] if no draft in progress or level does not exist
  def change_level_ordinal(framework_id, level_id, new_ordinal, reason:)
    ensure_draft_in_progress!
    raise "Level #{level_id} not found" unless @levels.key?(level_id)

    previous_ordinal = @levels[level_id][:ordinal]
    return if previous_ordinal == new_ordinal

    apply(Frameworks::Events::LevelOrdinalChanged.new(data: {
      framework_id: framework_id,
      level_id: level_id,
      new_ordinal: new_ordinal,
      previous_ordinal: previous_ordinal,
      reason: reason
    }))
  end

  # Adds a capability category to the framework.
  #
  # @param framework_id [String] UUID of the framework
  # @param category_id [String] UUID for the new category
  # @param name [String] display name
  # @param description [String, nil] optional description
  # @param ordinal [Integer, nil] display order
  # @raise [RuntimeError] if category already exists
  def add_capability_category(framework_id, category_id, name, description: nil, ordinal: nil)
    ensure_created!
    raise "Category #{category_id} already exists" if @capability_categories.key?(category_id)

    apply(Frameworks::Events::CapabilityCategoryAdded.new(data: {
      framework_id: framework_id,
      category_id: category_id,
      name: name,
      description: description,
      ordinal: ordinal
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

  # Updates a capability's name or description. Shape-preserving — editorial (applies live).
  #
  # @param framework_id [String] UUID of the framework
  # @param capability_id [String] UUID of the capability
  # @param name [String, nil] updated name
  # @param description [String, nil] updated description
  # @raise [RuntimeError] if framework not created or capability not found
  def update_capability(framework_id, capability_id, name: nil, description: nil)
    ensure_created!
    raise "Capability #{capability_id} not found" unless @capabilities.key?(capability_id)

    apply(Frameworks::Events::CapabilityUpdated.new(data: {
      framework_id: framework_id,
      capability_id: capability_id,
      name: name,
      description: description
    }.compact))
  end

  # Adds a capability to a category. Shape-changing — requires a draft.
  #
  # @param framework_id [String] UUID of the framework
  # @param capability_id [String] UUID for the new capability
  # @param stable_id [String] UUID linking this concept across versions
  # @param category_id [String] UUID of the parent category
  # @param name [String] display name
  # @param description [String, nil] optional description
  # @raise [RuntimeError] if no draft in progress, category not found, or capability already exists
  def add_capability(framework_id, capability_id, stable_id, category_id, name, description: nil)
    ensure_draft_in_progress!
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

  # Archives a capability. Shape-changing — requires a draft.
  #
  # Archived capabilities that existed at draft start must have a
  # corresponding MigrationMappingDefined event before publish_version
  # is called; otherwise publish will raise.
  #
  # @param framework_id [String] UUID of the framework
  # @param capability_id [String] UUID of the capability
  # @param reason [String] reason for archiving
  # @raise [RuntimeError] if no draft in progress, capability not found, or already archived
  def archive_capability(framework_id, capability_id, reason:)
    ensure_draft_in_progress!
    raise "Capability #{capability_id} not found" unless @capabilities.key?(capability_id)
    raise "Capability #{capability_id} already archived" if @capabilities[capability_id][:status] == :archived

    apply(Frameworks::Events::CapabilityArchived.new(data: {
      framework_id: framework_id,
      capability_id: capability_id,
      reason: reason
    }))
  end

  # Creates a capability-role binding. Shape-changing — requires a draft.
  #
  # @param framework_id [String] UUID of the framework
  # @param binding_id [String] UUID for the new binding
  # @param capability_id [String] UUID of the capability
  # @param role_id [String] UUID of the role
  # @param weight [BigDecimal] relative weight (default 1.0)
  # @param individual_tolerance [BigDecimal, nil] nil = category-governed,
  #   0 = mandatory, N = deficit capped at N before entering category pool
  # @raise [RuntimeError] if no draft in progress, capability or role not found, or binding already exists
  def create_capability_role_binding(framework_id, binding_id, capability_id, role_id, weight: 1.0, individual_tolerance: nil)
    ensure_draft_in_progress!
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

  # Removes a capability-role binding. Shape-changing — requires a draft.
  #
  # @param framework_id [String] UUID of the framework
  # @param binding_id [String] UUID of the binding
  # @raise [RuntimeError] if no draft in progress or binding does not exist
  def remove_capability_role_binding(framework_id, binding_id)
    ensure_draft_in_progress!
    raise "Binding #{binding_id} not found" unless @bindings.key?(binding_id)

    apply(Frameworks::Events::CapabilityRoleBindingRemoved.new(data: {
      framework_id: framework_id,
      binding_id: binding_id
    }))
  end

  # Sets a behavioural expectation for a capability at a level ordinal.
  # Shape-changing — requires a draft because it adds a new cell to the
  # (capability_stable_id, level_ordinal) rating grid.
  #
  # @param framework_id [String] UUID of the framework
  # @param expectation_id [String] UUID for the expectation
  # @param stable_id [String] UUID linking this concept across versions
  # @param capability_id [String] UUID of the parent capability
  # @param level_ordinal [Integer] seniority level ordinal
  # @param description [String] the expectation description
  # @raise [RuntimeError] if no draft in progress, capability not found, or expectation already exists
  def set_behavioural_expectation(framework_id, expectation_id, stable_id, capability_id, level_ordinal, description)
    ensure_draft_in_progress!
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

  # ── Collaborator commands ──

  # Adds a collaborator to the framework.
  #
  # @param framework_id [String] UUID of the framework
  # @param person_id [String] UUID of the person
  # @param collaborator_role [String] one of the 8 collaborator roles
  # @param scope_type [String, nil] nil for framework-wide, or entity type
  # @param scope_id [String, nil] UUID of the scoped entity
  # @param added_by [String] person_id of who added the collaborator
  # @raise [RuntimeError] if collaborator already has this role
  def add_collaborator(framework_id, person_id, collaborator_role, scope_type: nil, scope_id: nil, added_by:)
    ensure_created!
    key = collaborator_key(person_id, collaborator_role, scope_type, scope_id)
    raise "Collaborator already has this role" if @collaborators.key?(key)

    apply(Frameworks::Events::CollaboratorAdded.new(data: {
      framework_id: framework_id,
      person_id: person_id,
      collaborator_role: collaborator_role,
      scope_type: scope_type,
      scope_id: scope_id,
      added_by: added_by
    }))
  end

  # Changes a collaborator's role on the framework.
  #
  # @param framework_id [String] UUID of the framework
  # @param person_id [String] UUID of the collaborator
  # @param old_role [String] the current role being replaced
  # @param new_role [String] the new role
  # @param scope_type [String, nil] nil for framework-wide, or entity type
  # @param scope_id [String, nil] UUID of the scoped entity
  # @param changed_by [String] person_id of who made the change
  # @raise [RuntimeError] if collaborator does not have the old role
  def change_collaborator_role(framework_id, person_id, old_role, new_role, scope_type: nil, scope_id: nil, changed_by:)
    ensure_created!
    old_key = collaborator_key(person_id, old_role, scope_type, scope_id)
    raise "Collaborator does not have this role" unless @collaborators.key?(old_key)

    apply(Frameworks::Events::CollaboratorRoleChanged.new(data: {
      framework_id: framework_id,
      person_id: person_id,
      old_role: old_role,
      new_role: new_role,
      scope_type: scope_type,
      scope_id: scope_id,
      changed_by: changed_by
    }))
  end

  # Removes a collaborator from the framework.
  #
  # @param framework_id [String] UUID of the framework
  # @param person_id [String] UUID of the collaborator
  # @param collaborator_role [String] the role being removed
  # @param scope_type [String, nil] nil for framework-wide, or entity type
  # @param scope_id [String, nil] UUID of the scoped entity
  # @param removed_by [String] person_id of who removed the collaborator
  # @raise [RuntimeError] if collaborator does not have this role
  def remove_collaborator(framework_id, person_id, collaborator_role, scope_type: nil, scope_id: nil, removed_by:)
    ensure_created!
    key = collaborator_key(person_id, collaborator_role, scope_type, scope_id)
    raise "Collaborator does not have this role" unless @collaborators.key?(key)

    apply(Frameworks::Events::CollaboratorRemoved.new(data: {
      framework_id: framework_id,
      person_id: person_id,
      collaborator_role: collaborator_role,
      scope_type: scope_type,
      scope_id: scope_id,
      removed_by: removed_by
    }))
  end

  # ── Suggested edit commands ──

  # Returns whether a person has approval authority for a given entity type.
  #
  # Uses the three-tier review model:
  # - Tier 1 (RoleIllustration): any lead, editor, or owner
  # - Tier 2 (Capability/Category description): cap lead, cat lead, editor, owner
  # - Tier 3 (BehaviouralExpectation): cap lead (scoped), cat lead, editor, owner
  #
  # Falls back to true when no collaborators exist (bootstrapping).
  #
  # @param person_id [String] UUID of the person
  # @param target_entity_type [String, nil] type of entity being reviewed
  # @return [Boolean]
  def can_approve?(person_id, target_entity_type: nil)
    return true if @collaborators.empty?

    roles = roles_for_person(person_id)
    return false if roles.empty?

    tier = review_tier(target_entity_type)
    role_names = roles.map { |r| r[:role] }

    case tier
    when 1
      role_names.any? { |r| r.in?(%w[owner editor role_family_lead role_lead capability_category_lead capability_lead]) }
    when 2
      role_names.any? { |r| r.in?(%w[owner editor capability_category_lead capability_lead]) }
    when 3
      role_names.any? { |r| r.in?(%w[owner editor capability_category_lead capability_lead]) }
    else
      false
    end
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

  # Suggests creating a new framework entity. The target entity does not yet
  # exist; proposed_attributes carries the data needed to construct it on
  # approval. parent_id identifies the entity the new one would nest under
  # (e.g. expectation_id for an illustration, category_id for a capability).
  #
  # On approval, dispatches the matching add_* command on the aggregate. For
  # shape-changing entities (capability, level, behavioural_expectation), that
  # command's draft guard fires if no draft is in progress.
  #
  # @param framework_id [String] UUID of the framework
  # @param suggestion_id [String] UUID for the new suggestion
  # @param target_entity_type [String] type of entity to create (e.g. "capability")
  # @param proposed_attributes [Hash] attributes for the new entity
  # @param parent_id [String, nil] UUID of the parent entity, nil for framework-level entities
  # @param author_id [String] UUID of the user
  # @param rationale [String, nil] optional explanation
  # @raise [RuntimeError] if framework not created, parent not found, suggestion exists,
  #   entity type unknown, or proposed_attributes missing required keys
  def suggest_create(framework_id, suggestion_id, target_entity_type, proposed_attributes,
                     parent_id:, author_id:, rationale: nil)
    ensure_created!
    raise "Suggestion #{suggestion_id} already exists" if @pending_edits.key?(suggestion_id)
    raise_unless_parent_exists!(target_entity_type, parent_id)
    validate_proposed_attributes!(target_entity_type, proposed_attributes)

    apply(Frameworks::Events::EntityCreationSuggested.new(data: {
      framework_id: framework_id,
      suggestion_id: suggestion_id,
      target_entity_type: target_entity_type,
      proposed_attributes: proposed_attributes,
      parent_id: parent_id,
      author_id: author_id,
      rationale: rationale
    }.compact))
  end

  # Suggests deleting (or archiving) an existing framework entity.
  #
  # On approval, dispatches the matching destructive command on the aggregate
  # (archive_capability for "capability", remove_role_illustration for
  # "role_illustration"). Only entity types with available delete commands are
  # accepted — proposing the deletion of a role/level/role_family raises here.
  #
  # @param framework_id [String] UUID of the framework
  # @param suggestion_id [String] UUID for the new suggestion
  # @param target_entity_type [String] type of entity (e.g. "capability")
  # @param target_entity_id [String] UUID of the entity to delete
  # @param author_id [String] UUID of the user
  # @param rationale [String, nil] optional explanation
  # @raise [RuntimeError] if framework not created, entity not found, suggestion exists,
  #   or no delete command exists for this entity type
  def suggest_delete(framework_id, suggestion_id, target_entity_type, target_entity_id,
                     author_id:, rationale: nil)
    ensure_created!
    raise "Suggestion #{suggestion_id} already exists" if @pending_edits.key?(suggestion_id)
    raise_unless_entity_exists!(target_entity_type, target_entity_id)
    raise_unless_deletable!(target_entity_type)

    apply(Frameworks::Events::EntityDeletionSuggested.new(data: {
      framework_id: framework_id,
      suggestion_id: suggestion_id,
      target_entity_type: target_entity_type,
      target_entity_id: target_entity_id,
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
  # @return [String, nil] the created entity ID for :create suggestions, nil otherwise
  def approve_suggestion(suggestion_id, reviewer_id, comment: nil)
    ensure_created!
    suggestion = @pending_edits[suggestion_id]
    raise "Suggestion #{suggestion_id} not found" unless suggestion

    apply(Frameworks::Events::SuggestionApproved.new(data: {
      suggestion_id: suggestion_id,
      reviewer_id: reviewer_id,
      comment: comment
    }.compact))

    maybe_auto_open_draft_for(suggestion, reviewer_id)

    created_entity_id = case suggestion[:kind]
    when :create then apply_suggested_creation(suggestion)
    when :delete then apply_suggested_deletion(suggestion); nil
    else              apply_suggested_content_change(suggestion); nil
    end

    auto_reject_competing_suggestions(suggestion, reviewer_id)

    created_entity_id
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
  # @param author_id [String] UUID of the author (must match the original)
  # @raise [RuntimeError] if suggestion not found or author mismatch
  def withdraw_suggestion(suggestion_id, author_id)
    ensure_created!
    suggestion = @pending_edits[suggestion_id]
    raise "Suggestion #{suggestion_id} not found" unless suggestion
    raise "Only the author can withdraw their suggestion" unless suggestion[:author_id] == author_id

    apply(Frameworks::Events::SuggestionWithdrawn.new(data: {
      suggestion_id: suggestion_id
    }))
  end

  # ── Versioning commands ──

  # Configures scoring thresholds for framework-level assessment tuning.
  #
  # @param framework_id [String] UUID of the framework
  # @param mastery_threshold [BigDecimal, nil] ratio above baseline for mastery
  # @param promotion_score_threshold [BigDecimal, nil] ratio of next-level baseline
  #   required for promotion readiness score gate
  # @param overperformance_cap [Integer, nil] levels above assigned that count toward score
  # @param deficit_threshold [BigDecimal, nil] weighted deficit above which a capability is blocked
  # @raise [RuntimeError] if framework not created
  def configure_scoring_thresholds(framework_id, mastery_threshold: nil, promotion_score_threshold: nil,
                                   overperformance_cap: nil, deficit_threshold: nil)
    ensure_created!

    apply(Frameworks::Events::ScoringThresholdsConfigured.new(data: {
      framework_id: framework_id,
      mastery_threshold: mastery_threshold,
      promotion_score_threshold: promotion_score_threshold,
      overperformance_cap: overperformance_cap,
      deficit_threshold: deficit_threshold
    }))
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
  # The published projection will advance to include all shape-changing
  # events that accumulated during the draft phase. Editorial events have
  # already been applied live.
  #
  # @param framework_id [String] UUID of the framework
  # @param published_by [String] UUID of the user who published
  # @raise [RuntimeError] if no draft is in progress, or if any capability
  #   archived during this draft lacks a MigrationMappingDefined entry
  def publish_version(framework_id, published_by)
    ensure_created!
    raise "No draft in progress" unless @draft_in_progress
    if @archives_needing_mapping.any?
      pending = @archives_needing_mapping.to_a.join(", ")
      raise "Cannot publish: #{@archives_needing_mapping.size} archived " \
            "capability/capabilities lack migration mappings (#{pending}). " \
            "Call define_migration_mapping for each, with mapping_type of " \
            "'archived', 'evolved', or 'split'."
    end

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

  # Ensures the aggregate is inside a draft phase. Called by shape-changing
  # commands (commands that alter the (capability_stable_id, level_ordinal)
  # rating grid — see docs/architecture/framework-aggregate.md).
  #
  # @raise [RuntimeError] if no draft is in progress
  def ensure_draft_in_progress!
    ensure_created!
    raise "No draft in progress — call start_draft first" unless @draft_in_progress
  end

  # Auto-opens an implicit draft when approving a shape-changing suggestion
  # without an active draft. The draft stays open until owner/editor publishes
  # — letting bottom-up structural improvements accumulate without forcing
  # admins to bracket every approval with start_draft / publish_version.
  #
  # No-op if a draft is already in progress (the structural change joins it)
  # or if the suggestion is shape-preserving (which apply live).
  #
  # @param suggestion [Hash] pending_edits entry being approved
  # @param reviewer_id [String] approver's UUID — recorded as the draft owner
  def maybe_auto_open_draft_for(suggestion, reviewer_id)
    return if @draft_in_progress
    return unless shape_changing_suggestion?(suggestion)

    apply(Frameworks::Events::DraftVersionStarted.new(data: {
      framework_id: @framework_id,
      target_version: @current_version + 1,
      started_by: reviewer_id,
      auto_opened: true
    }))
  end

  # @param suggestion [Hash] pending_edits entry
  # @return [Boolean] whether approving this suggestion will require a draft
  def shape_changing_suggestion?(suggestion)
    case suggestion[:kind]
    when :create then SHAPE_CHANGING_CREATE_TYPES.include?(suggestion[:target_entity_type])
    when :delete then SHAPE_CHANGING_DELETE_TYPES.include?(suggestion[:target_entity_type])
    else              false
    end
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
      code: event.data[:code],
      is_entry: event.data[:is_entry]
    }
    # LevelAdded is shape-changing (ADR-16): levels added in a draft are
    # hidden in view mode until publish. Tracked for the ExplorerGraph.
    @draft_added_level_ids << event.data[:level_id] if @draft_in_progress
  end

  on Frameworks::Events::LevelUpdated do |event|
    level = @levels[event.data[:level_id]]
    level[:title] = event.data[:title] if event.data.key?(:title)
    level[:code] = event.data[:code] if event.data.key?(:code)
    level[:is_entry] = event.data[:is_entry] if event.data.key?(:is_entry)
  end

  on Frameworks::Events::LevelOrdinalChanged do |event|
    @levels[event.data[:level_id]][:ordinal] = event.data[:new_ordinal]
  end

  on Frameworks::Events::CapabilityCategoryAdded do |event|
    @capability_categories[event.data[:category_id]] = {
      name: event.data[:name],
      description: event.data[:description],
      ordinal: event.data[:ordinal]
    }
  end

  on Frameworks::Events::CapabilityCategoryUpdated do |event|
    cat = @capability_categories[event.data[:category_id]]
    cat[:name] = event.data[:name] if event.data.key?(:name)
    cat[:description] = event.data[:description] if event.data.key?(:description)
    cat[:ordinal] = event.data[:ordinal] if event.data.key?(:ordinal)
  end

  on Frameworks::Events::CapabilityAdded do |event|
    @capabilities[event.data[:capability_id]] = {
      stable_id: event.data[:stable_id],
      category_id: event.data[:category_id],
      name: event.data[:name],
      description: event.data[:description],
      status: :active
    }
    # Track capabilities added inside the current draft so archiving them
    # in the same draft doesn't require a migration mapping (nothing to migrate).
    @added_during_draft << event.data[:stable_id] if @draft_in_progress
    # Also track by native ID for the ExplorerGraph (distinct from the
    # stable_id tracking above — archive-mapping and graph-tagging have
    # different lookup needs).
    @draft_added_capability_ids << event.data[:capability_id] if @draft_in_progress
  end

  on Frameworks::Events::CapabilityUpdated do |event|
    cap = @capabilities[event.data[:capability_id]]
    cap[:name] = event.data[:name] if event.data.key?(:name)
    cap[:description] = event.data[:description] if event.data.key?(:description)
  end

  on Frameworks::Events::CapabilityArchived do |event|
    cap = @capabilities[event.data[:capability_id]]
    cap[:status] = :archived
    stable_id = cap[:stable_id]
    # Require a migration mapping unless the capability was also added in
    # this same draft (in which case there's nothing from the previous
    # published version to migrate).
    if @draft_in_progress && !@added_during_draft.include?(stable_id)
      @archives_needing_mapping << stable_id
    end
  end

  on Frameworks::Events::CapabilityRoleBindingCreated do |event|
    @bindings[event.data[:binding_id]] = {
      capability_id: event.data[:capability_id],
      role_id: event.data[:role_id],
      weight: event.data[:weight],
      individual_tolerance: event.data[:individual_tolerance]
    }
    # CapabilityRoleBindingCreated is shape-changing (ADR-16).
    @draft_added_binding_ids << event.data[:binding_id] if @draft_in_progress
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
      level_ordinal: event.data[:level_ordinal],
      description: event.data[:description]
    }
    # BehaviouralExpectationSet is shape-changing (ADR-16).
    @draft_added_expectation_ids << event.data[:expectation_id] if @draft_in_progress
  end

  on Frameworks::Events::BehaviouralExpectationUpdated do |event|
    exp = @expectations[event.data[:expectation_id]]
    exp[:description] = event.data[:description] if event.data.key?(:description)
  end

  on Frameworks::Events::RoleIllustrationAdded do |event|
    @illustrations[event.data[:illustration_id]] = {
      stable_id: event.data[:stable_id],
      expectation_id: event.data[:expectation_id],
      role_id: event.data[:role_id],
      ordinal: event.data[:ordinal],
      description: event.data[:description]
    }
  end

  on Frameworks::Events::RoleIllustrationUpdated do |event|
    ill = @illustrations[event.data[:illustration_id]]
    ill[:description] = event.data[:description] if event.data.key?(:description)
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
    @added_during_draft = Set.new
    @archives_needing_mapping = Set.new
    @draft_added_level_ids = Set.new
    @draft_added_capability_ids = Set.new
    @draft_added_binding_ids = Set.new
    @draft_added_expectation_ids = Set.new
  end

  on Frameworks::Events::FrameworkVersionPublished do |event|
    @current_version = event.data[:version]
    @draft_in_progress = false
    @draft_version = nil
    @migration_mappings = []
    @added_during_draft = Set.new
    @archives_needing_mapping = Set.new
    @draft_added_level_ids = Set.new
    @draft_added_capability_ids = Set.new
    @draft_added_binding_ids = Set.new
    @draft_added_expectation_ids = Set.new
  end

  on Frameworks::Events::MigrationMappingDefined do |event|
    @migration_mappings ||= []
    @migration_mappings << event.data[:mapping_id]
    # Clear the from_stable_id from the pending-mapping set — any mapping
    # type satisfies the "thought about it" requirement.
    @archives_needing_mapping.delete(event.data[:from_stable_id]) if event.data[:from_stable_id]
  end

  on Frameworks::Events::EditSuggested do |event|
    @pending_edits[event.data[:suggestion_id]] = {
      kind: :edit,
      suggestion_id: event.data[:suggestion_id],
      target_entity_type: event.data[:target_entity_type],
      target_entity_id: event.data[:target_entity_id],
      field: event.data[:field],
      suggested_value: event.data[:suggested_value],
      author_id: event.data[:author_id]
    }
  end

  on Frameworks::Events::EntityCreationSuggested do |event|
    @pending_edits[event.data[:suggestion_id]] = {
      kind: :create,
      suggestion_id: event.data[:suggestion_id],
      target_entity_type: event.data[:target_entity_type],
      proposed_attributes: event.data[:proposed_attributes],
      parent_id: event.data[:parent_id],
      author_id: event.data[:author_id]
    }
  end

  on Frameworks::Events::EntityDeletionSuggested do |event|
    @pending_edits[event.data[:suggestion_id]] = {
      kind: :delete,
      suggestion_id: event.data[:suggestion_id],
      target_entity_type: event.data[:target_entity_type],
      target_entity_id: event.data[:target_entity_id],
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

  on Frameworks::Events::CollaboratorAdded do |event|
    key = collaborator_key(event.data[:person_id], event.data[:collaborator_role],
                           event.data[:scope_type], event.data[:scope_id])
    @collaborators[key] = {
      role: event.data[:collaborator_role],
      person_id: event.data[:person_id],
      scope_type: event.data[:scope_type],
      scope_id: event.data[:scope_id]
    }
  end

  on Frameworks::Events::CollaboratorRoleChanged do |event|
    old_key = collaborator_key(event.data[:person_id], event.data[:old_role],
                               event.data[:scope_type], event.data[:scope_id])
    new_key = collaborator_key(event.data[:person_id], event.data[:new_role],
                               event.data[:scope_type], event.data[:scope_id])
    @collaborators.delete(old_key)
    @collaborators[new_key] = {
      role: event.data[:new_role],
      person_id: event.data[:person_id],
      scope_type: event.data[:scope_type],
      scope_id: event.data[:scope_id]
    }
  end

  on Frameworks::Events::CollaboratorRemoved do |event|
    key = collaborator_key(event.data[:person_id], event.data[:collaborator_role],
                           event.data[:scope_type], event.data[:scope_id])
    @collaborators.delete(key)
  end

  on Frameworks::Events::SuggestionCommented do |_event|
    # Future: store in comments — no state change needed in aggregate
  end

  # Builds a composite key for the collaborators hash.
  #
  # @param person_id [String]
  # @param role [String]
  # @param scope_type [String, nil]
  # @param scope_id [String, nil]
  # @return [String]
  def collaborator_key(person_id, role, scope_type, scope_id)
    "#{person_id}:#{role}:#{scope_type}:#{scope_id}"
  end

  # Returns all collaborator entries for a person.
  #
  # @param person_id [String]
  # @return [Array<Hash>]
  def roles_for_person(person_id)
    @collaborators.select { |_key, v| v[:person_id] == person_id }.values
  end

  # Determines the review tier for a target entity type.
  #
  # @param entity_type [String, nil]
  # @return [Integer] 1, 2, or 3
  def review_tier(entity_type)
    case entity_type
    when "RoleIllustration", "role_illustration" then 1
    when "Capability", "CapabilityCategory",
         "capability", "capability_category",
         "role", "role_family", "level" then 2
    when "BehaviouralExpectation", "behavioural_expectation" then 3
    else 1
    end
  end

  # Applies the actual content change event for an approved suggestion.
  #
  # Dispatches the matching editorial Updated event for the suggestion's
  # (target_entity_type, field) pair. Mirrors the existing role_illustration
  # pattern: emits the event directly with a rationale tag, rather than
  # calling the editorial command.
  #
  # @param suggestion [Hash] pending_edits entry
  # @return [void]
  # @raise [RuntimeError] if the (entity_type, field) combination is not supported
  def apply_suggested_content_change(suggestion) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength
    entity_id = suggestion[:target_entity_id]
    field = suggestion[:field]
    new_value = suggestion[:suggested_value]
    rationale_tag = "Applied via approved suggestion #{suggestion[:suggestion_id]}"

    case [ suggestion[:target_entity_type], field ]
    when [ "role_illustration", "description" ]
      apply(Frameworks::Events::RoleIllustrationUpdated.new(data: {
        framework_id: @framework_id, illustration_id: entity_id,
        new_description: new_value, rationale: rationale_tag
      }))
    when [ "behavioural_expectation", "description" ]
      apply(Frameworks::Events::BehaviouralExpectationUpdated.new(data: {
        framework_id: @framework_id, expectation_id: entity_id,
        new_description: new_value, rationale: rationale_tag
      }))
    when [ "capability", "name" ], [ "capability", "description" ]
      apply(Frameworks::Events::CapabilityUpdated.new(data: {
        framework_id: @framework_id, capability_id: entity_id,
        field.to_sym => new_value
      }))
    when [ "capability_category", "name" ], [ "capability_category", "description" ]
      apply(Frameworks::Events::CapabilityCategoryUpdated.new(data: {
        framework_id: @framework_id, category_id: entity_id,
        field.to_sym => new_value
      }))
    when [ "role_family", "name" ], [ "role_family", "description" ]
      apply(Frameworks::Events::RoleFamilyUpdated.new(data: {
        framework_id: @framework_id, role_family_id: entity_id,
        field.to_sym => new_value
      }))
    when [ "role", "name" ]
      apply(Frameworks::Events::RoleUpdated.new(data: {
        framework_id: @framework_id, role_id: entity_id, name: new_value
      }))
    when [ "level", "title" ]
      apply(Frameworks::Events::LevelUpdated.new(data: {
        framework_id: @framework_id, level_id: entity_id, title: new_value
      }))
    else
      raise "Unsupported suggestion target: #{suggestion[:target_entity_type]}/#{field}"
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
    when "behavioural_expectation"
      raise "Expectation #{entity_id} not found" unless @expectations.key?(entity_id)
    when "capability"
      raise "Capability #{entity_id} not found" unless @capabilities.key?(entity_id)
    when "capability_category"
      raise "Category #{entity_id} not found" unless @capability_categories.key?(entity_id)
    when "role"
      raise "Role #{entity_id} not found" unless @roles.key?(entity_id)
    when "role_family"
      raise "Role family #{entity_id} not found" unless @role_families.key?(entity_id)
    when "level"
      raise "Level #{entity_id} not found" unless @levels.key?(entity_id)
    else
      raise "Unknown entity type: #{entity_type}"
    end
  end

  # Raises unless the parent entity for a creation suggestion exists.
  #
  # Framework-level entities (role_family, capability_category) have no
  # parent — parent_id is allowed to be nil for those.
  #
  # @param entity_type [String]
  # @param parent_id [String, nil]
  # @raise [RuntimeError] if parent not found or entity type unknown
  def raise_unless_parent_exists!(entity_type, parent_id) # rubocop:disable Metrics/CyclomaticComplexity
    case entity_type
    when "role_illustration"
      raise "Expectation #{parent_id} not found" unless @expectations.key?(parent_id)
    when "behavioural_expectation"
      raise "Capability #{parent_id} not found" unless @capabilities.key?(parent_id)
    when "capability"
      raise "Category #{parent_id} not found" unless @capability_categories.key?(parent_id)
    when "role"
      raise "Role family #{parent_id} not found" unless @role_families.key?(parent_id)
    when "level"
      raise "Role #{parent_id} not found" unless @roles.key?(parent_id)
    when "capability_category", "role_family"
      # Framework-level entities — no parent required.
      nil
    else
      raise "Unknown entity type: #{entity_type}"
    end
  end

  REQUIRED_CREATION_KEYS = {
    "role_illustration" => %i[role_id description],
    "behavioural_expectation" => %i[level_ordinal description],
    "capability" => %i[name],
    "capability_category" => %i[name],
    "role" => %i[name code track],
    "role_family" => %i[name],
    "level" => %i[ordinal title code]
  }.freeze

  # Validates the proposed_attributes hash for a creation suggestion has the
  # keys required to dispatch the matching add_* command on approval.
  #
  # Does NOT pre-validate semantics (uniqueness, allowed values) — that runs
  # when the command actually executes after approval.
  #
  # @param entity_type [String]
  # @param attrs [Hash]
  # @raise [RuntimeError] if entity type unknown or required keys missing
  def validate_proposed_attributes!(entity_type, attrs)
    required = REQUIRED_CREATION_KEYS[entity_type]
    raise "Unknown entity type: #{entity_type}" if required.nil?

    attrs ||= {}
    missing = required - attrs.keys.map(&:to_sym)
    return if missing.empty?

    raise "Missing proposed_attributes for #{entity_type}: #{missing.join(', ')}"
  end

  DELETABLE_ENTITY_TYPES = %w[role_illustration capability].freeze

  # Raises unless the entity type has a destructive command available.
  #
  # @param entity_type [String]
  # @raise [RuntimeError] if no delete command exists for this type
  def raise_unless_deletable!(entity_type)
    return if DELETABLE_ENTITY_TYPES.include?(entity_type)

    raise "Cannot suggest deletion for #{entity_type} — no delete command available"
  end

  # Dispatches the matching add_* command for an approved creation suggestion.
  #
  # New entity ids (and stable_ids where required) are generated here, since
  # the suggestion deliberately does not pre-allocate them.
  #
  # @param suggestion [Hash] pending_edits entry with kind: :create
  # @raise [RuntimeError] if the entity type is not supported
  # @return [String] the generated entity ID for the created record
  def apply_suggested_creation(suggestion) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength
    type = suggestion[:target_entity_type]
    attrs = (suggestion[:proposed_attributes] || {}).transform_keys(&:to_sym)
    parent_id = suggestion[:parent_id]

    entity_id = SecureRandom.uuid_v7
    stable_id = SecureRandom.uuid_v7

    case type
    when "role_illustration"
      add_role_illustration(@framework_id,
                            entity_id, stable_id,
                            parent_id, attrs[:role_id],
                            attrs[:ordinal] || next_illustration_ordinal(parent_id, attrs[:role_id]),
                            attrs[:description])
    when "behavioural_expectation"
      set_behavioural_expectation(@framework_id,
                                  entity_id, stable_id,
                                  parent_id, attrs[:level_ordinal], attrs[:description])
    when "capability"
      add_capability(@framework_id,
                     entity_id, stable_id,
                     parent_id, attrs[:name], description: attrs[:description])
    when "capability_category"
      add_capability_category(@framework_id, entity_id,
                              attrs[:name], description: attrs[:description], ordinal: attrs[:ordinal])
    when "role"
      add_role(@framework_id, entity_id, parent_id,
               attrs[:name], attrs[:code], attrs[:track])
    when "role_family"
      add_role_family(@framework_id, entity_id,
                      attrs[:name], description: attrs[:description])
    when "level"
      add_level(@framework_id, entity_id, parent_id,
                attrs[:ordinal], attrs[:title], attrs[:code], is_entry: attrs.fetch(:is_entry, false))
    else
      raise "Unsupported creation target: #{type}"
    end

    entity_id
  end

  # Dispatches the matching destructive command for an approved deletion suggestion.
  #
  # @param suggestion [Hash] pending_edits entry with kind: :delete
  # @raise [RuntimeError] if the entity type is not supported
  def apply_suggested_deletion(suggestion)
    type = suggestion[:target_entity_type]
    entity_id = suggestion[:target_entity_id]
    rationale_tag = "Applied via approved suggestion #{suggestion[:suggestion_id]}"

    case type
    when "role_illustration"
      remove_role_illustration(@framework_id, entity_id, reason: rationale_tag)
    when "capability"
      archive_capability(@framework_id, entity_id, reason: rationale_tag)
    else
      raise "Unsupported deletion target: #{type}"
    end
  end

  # Returns the next ordinal for a new illustration on the given expectation
  # and role. Used by suggest_create when ordinal isn't specified in
  # proposed_attributes.
  #
  # @param expectation_id [String]
  # @param role_id [String]
  # @return [Integer]
  def next_illustration_ordinal(expectation_id, role_id)
    siblings = @illustrations.values.select do |i|
      i[:expectation_id] == expectation_id && i[:role_id] == role_id
    end
    (siblings.map { |i| i[:ordinal] || 0 }.max || 0) + 1
  end

  # Auto-rejects pending suggestions superseded by an approved one.
  #
  # - approving an :edit rejects edits on the same entity_id + same field
  # - approving a :delete rejects all edits and deletes on the same entity
  #   (the entity is going away — pending edits are moot)
  # - approving a :create does not auto-reject anything (different entities)
  #
  # @param approved [Hash] the just-approved pending_edits entry
  # @param reviewer_id [String]
  def auto_reject_competing_suggestions(approved, reviewer_id)
    return if approved[:kind] == :create

    competing_suggestions = @pending_edits.values.select do |competing|
      competing[:suggestion_id] != approved[:suggestion_id] &&
        competing_supersedes?(approved, competing)
    end

    competing_suggestions.each do |competing|
      apply(Frameworks::Events::SuggestionRejected.new(data: {
        suggestion_id: competing[:suggestion_id],
        reviewer_id: reviewer_id,
        comment: "Superseded by approved suggestion"
      }))
    end
  end

  # Determines whether the approved suggestion supersedes a competing one.
  #
  # @param approved [Hash]
  # @param competing [Hash]
  # @return [Boolean]
  def competing_supersedes?(approved, competing)
    case approved[:kind]
    when :edit
      competing[:kind] == :edit &&
        competing[:target_entity_id] == approved[:target_entity_id] &&
        competing[:field] == approved[:field]
    when :delete
      competing[:kind] != :create &&
        competing[:target_entity_type] == approved[:target_entity_type] &&
        competing[:target_entity_id] == approved[:target_entity_id]
    else
      false
    end
  end
end
