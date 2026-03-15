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
  # @param requirement_type [String] "must_have" or "flexible"
  # @raise [RuntimeError] if capability or role not found, or binding already exists
  def create_capability_role_binding(framework_id, binding_id, capability_id, role_id, weight: 1.0, requirement_type: "must_have")
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
      requirement_type: requirement_type
    }))
  end

  # Updates a capability-role binding.
  #
  # @param framework_id [String] UUID of the framework
  # @param binding_id [String] UUID of the binding
  # @param weight [BigDecimal, nil] updated weight
  # @param requirement_type [String, nil] updated requirement type
  # @raise [RuntimeError] if binding does not exist
  def update_capability_role_binding(framework_id, binding_id, weight: nil, requirement_type: nil)
    ensure_created!
    raise "Binding #{binding_id} not found" unless @bindings.key?(binding_id)

    apply(Frameworks::Events::CapabilityRoleBindingUpdated.new(data: {
      framework_id: framework_id,
      binding_id: binding_id,
      weight: weight,
      requirement_type: requirement_type
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

  private

  # @raise [RuntimeError] if the framework has not been created
  def ensure_created!
    raise "Framework not yet created" unless @status == :created
  end

  on Frameworks::Events::FrameworkCreated do |event|
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
      requirement_type: event.data[:requirement_type]
    }
  end

  on Frameworks::Events::CapabilityRoleBindingUpdated do |event|
    binding = @bindings[event.data[:binding_id]]
    binding[:weight] = event.data[:weight] if event.data.key?(:weight)
    binding[:requirement_type] = event.data[:requirement_type] if event.data.key?(:requirement_type)
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
end
