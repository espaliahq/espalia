# frozen_string_literal: true

# Synchronous projection that materialises published framework state.
#
# Subscribes to Framework aggregate events and maintains the
# FrameworkState read models. Runs in the same transaction
# as the event publish.
#
# During a draft phase (between DraftVersionStarted and
# FrameworkVersionPublished), structural events are skipped.
# On publish, the entire projection is rebuilt from the event stream.
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
      Frameworks::Events::RoleIllustrationReordered,
      Frameworks::Events::DraftVersionStarted,
      Frameworks::Events::FrameworkVersionPublished,
      Frameworks::Events::MigrationMappingDefined,
      Frameworks::Events::EditSuggested,
      Frameworks::Events::SuggestionAmended,
      Frameworks::Events::SuggestionApproved,
      Frameworks::Events::SuggestionRejected,
      Frameworks::Events::SuggestionWithdrawn,
      Frameworks::Events::SuggestionCommented
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
    # Versioning events — always processed
    when Frameworks::Events::FrameworkCreated then handle_framework_created(event)
    when Frameworks::Events::DraftVersionStarted then handle_draft_version_started(event)
    when Frameworks::Events::FrameworkVersionPublished then handle_framework_version_published(event)
    when Frameworks::Events::MigrationMappingDefined then handle_migration_mapping_defined(event)
    # Suggestion events — always processed, independent of draft state
    when Frameworks::Events::EditSuggested then handle_edit_suggested(event)
    when Frameworks::Events::SuggestionAmended then handle_suggestion_amended(event)
    when Frameworks::Events::SuggestionApproved then handle_suggestion_approved(event)
    when Frameworks::Events::SuggestionRejected then handle_suggestion_rejected(event)
    when Frameworks::Events::SuggestionWithdrawn then handle_suggestion_withdrawn(event)
    when Frameworks::Events::SuggestionCommented then nil # future: comments table
    # Structural events — skipped during draft
    else
      handle_structural_event(event)
    end
  end
  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/MethodLength

  # ── Versioning handlers ──

  def handle_draft_version_started(event)
    framework = find_framework(event)
    framework.update!(
      draft_in_progress: true,
      draft_version: event.data[:target_version]
    )
  end

  def handle_framework_version_published(event)
    framework = find_framework(event)
    rebuild_framework_projection(framework, event)
  end

  def handle_migration_mapping_defined(event) # rubocop:disable Metrics/MethodLength
    # Find the framework to get the draft version
    framework = find_framework(event)
    FrameworkState::MigrationMapping.create!(
      framework_id: event.data[:framework_id],
      mapping_id: event.data[:mapping_id],
      published_version: framework.draft_version || 0,
      from_stable_id: event.data[:from_stable_id],
      to_stable_id: event.data[:to_stable_id],
      mapping_type: event.data[:mapping_type],
      requires_reassessment: event.data[:requires_reassessment] || false,
      reason: event.data[:reason]
    )
  end

  # ── Structural event dispatch (draft-guarded) ──

  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength
  def handle_structural_event(event)
    framework = find_framework(event)
    return if framework&.draft_in_progress

    case event
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

  # ── Rebuild on publish ──

  # Rebuilds the entire published projection for a framework from the event stream.
  #
  # Deletes all child read models and replays every event, treating the
  # replay as a non-draft context (so all structural events apply).
  #
  # @param framework [FrameworkState::Framework]
  # @param publish_event [RubyEventStore::Event] the FrameworkVersionPublished event
  def rebuild_framework_projection(framework, publish_event) # rubocop:disable Metrics/MethodLength
    framework_id = framework.framework_id

    # Delete all child read models for this framework
    destroy_framework_children(framework)

    # Update framework version fields before replay
    framework.update!(
      current_published_version: publish_event.data[:version],
      draft_in_progress: false,
      draft_version: nil
    )

    # Replay all events in the stream (except versioning events)
    stream = EventStreamNaming.framework_stream(framework_id)
    event_store = Rails.configuration.event_store
    event_store.read.stream(stream).each do |event|
      # Skip versioning and framework-created events during replay
      next if event.is_a?(Frameworks::Events::FrameworkCreated)
      next if event.is_a?(Frameworks::Events::DraftVersionStarted)
      next if event.is_a?(Frameworks::Events::FrameworkVersionPublished)
      next if event.is_a?(Frameworks::Events::MigrationMappingDefined)

      # Replay structural events directly (bypass draft guard)
      replay_structural_event(event)
    end
  end

  # Replays a structural event during rebuild (no draft guard).
  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength
  def replay_structural_event(event)
    case event
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

  # Destroys all child read model records for a framework.
  def destroy_framework_children(framework) # rubocop:disable Metrics/MethodLength
    framework_id = framework.framework_id
    FrameworkState::RoleIllustration.joins(:expectation)
      .where(framework_behavioural_expectations: {
        capability_id: FrameworkState::Capability
          .joins(:category)
          .where(framework_capability_categories: { framework_id: framework_id })
          .select(:capability_id)
      }).delete_all
    FrameworkState::BehaviouralExpectation.where(
      capability_id: FrameworkState::Capability
        .joins(:category)
        .where(framework_capability_categories: { framework_id: framework_id })
        .select(:capability_id)
    ).delete_all
    FrameworkState::CapabilityRoleBinding.where(
      capability_id: FrameworkState::Capability
        .joins(:category)
        .where(framework_capability_categories: { framework_id: framework_id })
        .select(:capability_id)
    ).delete_all
    FrameworkState::Capability.where(
      category_id: FrameworkState::CapabilityCategory
        .where(framework_id: framework_id)
        .select(:category_id)
    ).delete_all
    FrameworkState::CapabilityCategory.where(framework_id: framework_id).delete_all
    FrameworkState::Level.where(
      role_id: FrameworkState::Role
        .joins(:role_family)
        .where(framework_role_families: { framework_id: framework_id })
        .select(:role_id)
    ).delete_all
    FrameworkState::Role.where(
      role_family_id: FrameworkState::RoleFamily
        .where(framework_id: framework_id)
        .select(:role_family_id)
    ).delete_all
    FrameworkState::RoleFamily.where(framework_id: framework_id).delete_all
  end

  # ── Individual structural handlers ──

  def handle_framework_created(event)
    FrameworkState::Framework.create!(
      framework_id: event.data[:framework_id],
      name: event.data[:name],
      current_published_version: 0,
      draft_in_progress: false
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

  # ── Suggestion handlers ──

  def handle_edit_suggested(event)
    FrameworkState::SuggestedEdit.create!(
      build_suggested_edit_attrs(event)
    )
  end

  def build_suggested_edit_attrs(event) # rubocop:disable Metrics/MethodLength
    entity_id = event.data[:target_entity_id]
    entity_type = event.data[:target_entity_type]
    {
      framework_id: event.data[:framework_id],
      suggestion_id: event.data[:suggestion_id],
      target_entity_type: entity_type,
      target_entity_id: entity_id,
      field: event.data[:field],
      current_value: current_entity_value(entity_type, entity_id, event.data[:field]),
      suggested_value: event.data[:suggested_value],
      author_id: event.data[:author_id],
      rationale: event.data[:rationale],
      status: "pending"
    }
  end

  def handle_suggestion_amended(event)
    record = FrameworkState::SuggestedEdit.find_by!(suggestion_id: event.data[:suggestion_id])
    record.update!(
      suggested_value: event.data[:new_suggested_value],
      rationale: event.data[:rationale] || record.rationale
    )
  end

  def handle_suggestion_approved(event)
    record = FrameworkState::SuggestedEdit.find_by!(suggestion_id: event.data[:suggestion_id])
    record.update!(
      status: "approved",
      reviewed_by: event.data[:reviewer_id],
      reviewed_at: event.metadata[:timestamp],
      reviewer_comment: event.data[:comment]
    )
  end

  def handle_suggestion_rejected(event)
    record = FrameworkState::SuggestedEdit.find_by!(suggestion_id: event.data[:suggestion_id])
    record.update!(
      status: "rejected",
      reviewed_by: event.data[:reviewer_id],
      reviewed_at: event.metadata[:timestamp],
      reviewer_comment: event.data[:comment]
    )
  end

  def handle_suggestion_withdrawn(event)
    record = FrameworkState::SuggestedEdit.find_by!(suggestion_id: event.data[:suggestion_id])
    record.update!(status: "withdrawn")
  end

  # Returns the current value of a field on an entity for snapshot purposes.
  #
  # @param entity_type [String]
  # @param entity_id [String]
  # @param field [String]
  # @return [String, nil]
  def current_entity_value(entity_type, entity_id, field)
    case entity_type
    when "role_illustration"
      record = FrameworkState::RoleIllustration.find_by(illustration_id: entity_id)
      record&.public_send(field)
    end
  end

  # ── Helpers ──

  # Finds the framework read model from event data.
  #
  # @param event [RubyEventStore::Event]
  # @return [FrameworkState::Framework, nil]
  def find_framework(event)
    FrameworkState::Framework.find_by(framework_id: event.data[:framework_id])
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
