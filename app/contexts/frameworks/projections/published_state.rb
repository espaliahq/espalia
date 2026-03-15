# frozen_string_literal: true

# Synchronous projection that materialises published framework state.
#
# Subscribes to Framework aggregate events and maintains the
# FrameworkState read models. Runs in the same transaction
# as the event publish.
#
class Frameworks::Projections::PublishedState
  # All event classes this projection handles.
  #
  # @return [Array<Class>] event classes
  def self.handled_events
    [
      Frameworks::Events::FrameworkCreated,
      Frameworks::Events::RoleFamilyAdded,
      Frameworks::Events::RoleFamilyUpdated,
      Frameworks::Events::RoleAdded,
      Frameworks::Events::RoleUpdated,
      Frameworks::Events::LevelAdded,
      Frameworks::Events::LevelUpdated,
      Frameworks::Events::CapabilityCategoryAdded,
      Frameworks::Events::CapabilityCategoryUpdated,
      Frameworks::Events::CapabilityAdded,
      Frameworks::Events::CapabilityArchived,
      Frameworks::Events::CapabilityRoleBindingCreated,
      Frameworks::Events::CapabilityRoleBindingUpdated,
      Frameworks::Events::CapabilityRoleBindingRemoved,
      Frameworks::Events::BehaviouralExpectationSet,
      Frameworks::Events::BehaviouralExpectationUpdated,
      Frameworks::Events::RoleIllustrationAdded,
      Frameworks::Events::RoleIllustrationUpdated,
      Frameworks::Events::RoleIllustrationRemoved,
      Frameworks::Events::RoleIllustrationReordered
    ]
  end

  # @param event [RubyEventStore::Event]
  def call(event)
    with_tenant(event) do
      handle(event)
    end
  end

  private

  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength
  def handle(event)
    case event
    when Frameworks::Events::FrameworkCreated then handle_framework_created(event)
    when Frameworks::Events::RoleFamilyAdded then handle_role_family_added(event)
    when Frameworks::Events::RoleFamilyUpdated then handle_role_family_updated(event)
    when Frameworks::Events::RoleAdded then handle_role_added(event)
    when Frameworks::Events::RoleUpdated then handle_role_updated(event)
    when Frameworks::Events::LevelAdded then handle_level_added(event)
    when Frameworks::Events::LevelUpdated then handle_level_updated(event)
    when Frameworks::Events::CapabilityCategoryAdded then handle_capability_category_added(event)
    when Frameworks::Events::CapabilityCategoryUpdated then handle_capability_category_updated(event)
    when Frameworks::Events::CapabilityAdded then handle_capability_added(event)
    when Frameworks::Events::CapabilityArchived then handle_capability_archived(event)
    when Frameworks::Events::CapabilityRoleBindingCreated then handle_binding_created(event)
    when Frameworks::Events::CapabilityRoleBindingUpdated then handle_binding_updated(event)
    when Frameworks::Events::CapabilityRoleBindingRemoved then handle_binding_removed(event)
    when Frameworks::Events::BehaviouralExpectationSet then handle_expectation_set(event)
    when Frameworks::Events::BehaviouralExpectationUpdated then handle_expectation_updated(event)
    when Frameworks::Events::RoleIllustrationAdded then handle_illustration_added(event)
    when Frameworks::Events::RoleIllustrationUpdated then handle_illustration_updated(event)
    when Frameworks::Events::RoleIllustrationRemoved then handle_illustration_removed(event)
    when Frameworks::Events::RoleIllustrationReordered then handle_illustration_reordered(event)
    end
  end
  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/MethodLength

  def handle_framework_created(event)
    FrameworkState::Framework.create!(
      framework_id: event.data[:framework_id],
      name: event.data[:name]
    )
  end

  def handle_role_family_added(event)
    FrameworkState::RoleFamily.create!(
      framework_id: event.data[:framework_id],
      role_family_id: event.data[:role_family_id],
      name: event.data[:name],
      description: event.data[:description]
    )
  end

  def handle_role_family_updated(event)
    record = FrameworkState::RoleFamily.find_by!(role_family_id: event.data[:role_family_id])
    attrs = event.data.slice(:name, :description).compact
    record.update!(attrs) if attrs.any?
  end

  def handle_role_added(event)
    FrameworkState::Role.create!(
      role_family_id: event.data[:role_family_id],
      role_id: event.data[:role_id],
      name: event.data[:name],
      code: event.data[:code],
      track: event.data[:track]
    )
  end

  def handle_role_updated(event)
    record = FrameworkState::Role.find_by!(role_id: event.data[:role_id])
    attrs = event.data.slice(:name, :code, :track).compact
    record.update!(attrs) if attrs.any?
  end

  def handle_level_added(event)
    FrameworkState::Level.create!(
      role_id: event.data[:role_id],
      level_id: event.data[:level_id],
      ordinal: event.data[:ordinal],
      title: event.data[:title],
      code: event.data[:code],
      is_entry: event.data[:is_entry] || false
    )
  end

  def handle_level_updated(event)
    record = FrameworkState::Level.find_by!(level_id: event.data[:level_id])
    attrs = event.data.slice(:ordinal, :title, :code).compact
    record.update!(attrs) if attrs.any?
  end

  def handle_capability_category_added(event)
    FrameworkState::CapabilityCategory.create!(
      framework_id: event.data[:framework_id],
      category_id: event.data[:category_id],
      name: event.data[:name],
      description: event.data[:description],
      ordinal: event.data[:ordinal]
    )
  end

  def handle_capability_category_updated(event)
    record = FrameworkState::CapabilityCategory.find_by!(category_id: event.data[:category_id])
    attrs = event.data.slice(:name, :description, :ordinal).compact
    record.update!(attrs) if attrs.any?
  end

  def handle_capability_added(event)
    FrameworkState::Capability.create!(
      category_id: event.data[:category_id],
      capability_id: event.data[:capability_id],
      stable_id: event.data[:stable_id],
      name: event.data[:name],
      description: event.data[:description],
      status: "active"
    )
  end

  def handle_capability_archived(event)
    record = FrameworkState::Capability.find_by!(capability_id: event.data[:capability_id])
    record.update!(status: "archived")
  end

  def handle_binding_created(event)
    FrameworkState::CapabilityRoleBinding.create!(
      binding_id: event.data[:binding_id],
      capability_id: event.data[:capability_id],
      role_id: event.data[:role_id],
      weight: event.data[:weight],
      requirement_type: event.data[:requirement_type]
    )
  end

  def handle_binding_updated(event)
    record = FrameworkState::CapabilityRoleBinding.find_by!(binding_id: event.data[:binding_id])
    attrs = event.data.slice(:weight, :requirement_type).compact
    record.update!(attrs) if attrs.any?
  end

  def handle_binding_removed(event)
    FrameworkState::CapabilityRoleBinding.find_by!(binding_id: event.data[:binding_id]).destroy!
  end

  def handle_expectation_set(event)
    FrameworkState::BehaviouralExpectation.create!(
      expectation_id: event.data[:expectation_id],
      stable_id: event.data[:stable_id],
      capability_id: event.data[:capability_id],
      level_ordinal: event.data[:level_ordinal],
      description: event.data[:description]
    )
  end

  def handle_expectation_updated(event)
    record = FrameworkState::BehaviouralExpectation.find_by!(expectation_id: event.data[:expectation_id])
    record.update!(description: event.data[:new_description])
  end

  def handle_illustration_added(event)
    FrameworkState::RoleIllustration.create!(
      illustration_id: event.data[:illustration_id],
      stable_id: event.data[:stable_id],
      expectation_id: event.data[:expectation_id],
      role_id: event.data[:role_id],
      ordinal: event.data[:ordinal],
      description: event.data[:description]
    )
  end

  def handle_illustration_updated(event)
    record = FrameworkState::RoleIllustration.find_by!(illustration_id: event.data[:illustration_id])
    record.update!(description: event.data[:new_description])
  end

  def handle_illustration_removed(event)
    FrameworkState::RoleIllustration.find_by!(illustration_id: event.data[:illustration_id]).destroy!
  end

  def handle_illustration_reordered(event)
    event.data[:new_ordering].each_with_index do |illustration_id, index|
      record = FrameworkState::RoleIllustration.find_by(illustration_id: illustration_id)
      record&.update!(ordinal: index + 1)
    end
  end

  # Sets tenant context from event metadata for projection writes.
  #
  # @param event [RubyEventStore::Event]
  # @yield block to execute within tenant context
  def with_tenant(event, &block)
    tenant = Tenant.find(event.metadata[:tenant_id])
    ActsAsTenant.with_tenant(tenant, &block)
  end
end
