# frozen_string_literal: true

# Synchronous projection that materialises published framework state.
#
# Subscribes to Framework aggregate events and maintains the
# FrameworkState read models. Runs in the same transaction
# as the event publish.
#
# Events are classified along two axes:
#
# 1. **Shape-changing** events alter the (capability_stable_id, level_ordinal)
#    rating grid that in-flight assessment cycles depend on. They are
#    deferred during a draft phase (between DraftVersionStarted and
#    FrameworkVersionPublished). On publish, the projection is rebuilt
#    from the event stream so they become visible.
#
# 2. **Editorial / shape-preserving** events (renames, rephrasings,
#    illustrations, binding weight tweaks) apply immediately regardless
#    of draft state. They do not affect ratings.
#
# See docs/architecture/framework-aggregate.md for the full classification.
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
      Frameworks::Events::LevelOrdinalChanged,
      Frameworks::Events::CapabilityCategoryAdded,
      Frameworks::Events::CapabilityCategoryUpdated,
      Frameworks::Events::CapabilityAdded,
      Frameworks::Events::CapabilityUpdated,
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
      Frameworks::Events::EntityCreationSuggested,
      Frameworks::Events::EntityDeletionSuggested,
      Frameworks::Events::SuggestionAmended,
      Frameworks::Events::SuggestionApproved,
      Frameworks::Events::SuggestionRejected,
      Frameworks::Events::SuggestionWithdrawn,
      Frameworks::Events::SuggestionCommented,
      Frameworks::Events::ScoringThresholdsConfigured,
      Frameworks::Events::CollaboratorAdded,
      Frameworks::Events::CollaboratorRoleChanged,
      Frameworks::Events::CollaboratorRemoved
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
    # ── Meta / versioning — always live ──
    when Frameworks::Events::FrameworkCreated then handle_framework_created(event)
    when Frameworks::Events::DraftVersionStarted then handle_draft_version_started(event)
    when Frameworks::Events::FrameworkVersionPublished then handle_framework_version_published(event)
    when Frameworks::Events::MigrationMappingDefined then handle_migration_mapping_defined(event)

    # ── Suggestions — always live ──
    when Frameworks::Events::EditSuggested then handle_edit_suggested(event)
    when Frameworks::Events::EntityCreationSuggested then handle_entity_creation_suggested(event)
    when Frameworks::Events::EntityDeletionSuggested then handle_entity_deletion_suggested(event)
    when Frameworks::Events::SuggestionAmended then handle_suggestion_amended(event)
    when Frameworks::Events::SuggestionApproved then handle_suggestion_approved(event)
    when Frameworks::Events::SuggestionRejected then handle_suggestion_rejected(event)
    when Frameworks::Events::SuggestionWithdrawn then handle_suggestion_withdrawn(event)
    when Frameworks::Events::SuggestionCommented then nil # future: comments table

    # ── Scoring & collaborators — always live ──
    when Frameworks::Events::ScoringThresholdsConfigured then handle_scoring_thresholds_configured(event)
    when Frameworks::Events::CollaboratorAdded then handle_collaborator_added(event)
    when Frameworks::Events::CollaboratorRoleChanged then handle_collaborator_role_changed(event)
    when Frameworks::Events::CollaboratorRemoved then handle_collaborator_removed(event)

    # ── Editorial (shape-preserving) — always live ──
    when Frameworks::Events::RoleFamilyAdded then handle_role_family_added(event)
    when Frameworks::Events::RoleFamilyUpdated then handle_role_family_updated(event)
    when Frameworks::Events::RoleAdded then handle_role_added(event)
    when Frameworks::Events::RoleUpdated then handle_role_updated(event)
    when Frameworks::Events::LevelUpdated then handle_level_updated(event)
    when Frameworks::Events::CapabilityCategoryAdded then handle_capability_category_added(event)
    when Frameworks::Events::CapabilityCategoryUpdated then handle_capability_category_updated(event)
    when Frameworks::Events::CapabilityUpdated then handle_capability_updated(event)
    when Frameworks::Events::CapabilityRoleBindingUpdated then handle_binding_updated(event)
    when Frameworks::Events::BehaviouralExpectationUpdated then handle_expectation_updated(event)
    when Frameworks::Events::RoleIllustrationAdded then handle_illustration_added(event)
    when Frameworks::Events::RoleIllustrationUpdated then handle_illustration_updated(event)
    when Frameworks::Events::RoleIllustrationRemoved then handle_illustration_removed(event)
    when Frameworks::Events::RoleIllustrationReordered then handle_illustration_reordered(event)

    # ── Shape-changing — deferred while draft_in_progress, replayed on publish ──
    else
      handle_shape_changing_event(event)
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

  # ── Shape-changing event dispatch (deferred during draft) ──
  #
  # Shape-changing events are guaranteed by Frameworks::Aggregate's
  # ensure_draft_in_progress! guard to be emitted only inside a draft.
  # During draft we skip them in the published view; on FrameworkVersionPublished,
  # rebuild_framework_projection replays every event (via handle) against a
  # non-draft framework state, so these events become visible.
  def handle_shape_changing_event(event) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength
    framework = find_framework(event)
    return if framework&.draft_in_progress

    case event
    when Frameworks::Events::LevelAdded then handle_level_added(event)
    when Frameworks::Events::LevelOrdinalChanged then handle_level_ordinal_changed(event)
    when Frameworks::Events::CapabilityAdded then handle_capability_added(event)
    when Frameworks::Events::CapabilityArchived then handle_capability_archived(event)
    when Frameworks::Events::CapabilityRoleBindingCreated then handle_binding_created(event)
    when Frameworks::Events::CapabilityRoleBindingRemoved then handle_binding_removed(event)
    when Frameworks::Events::BehaviouralExpectationSet then handle_expectation_set(event)
    end
  end

  # ── Rebuild on publish ──

  # Rebuilds the entire published projection for a framework from the event stream.
  #
  # Deletes all child read models and replays every non-meta event via handle().
  # Because draft_in_progress is set to false BEFORE replay starts, the
  # shape-changing event dispatch applies all events (rather than deferring them).
  #
  # @param framework [FrameworkState::Framework]
  # @param publish_event [RubyEventStore::Event] the FrameworkVersionPublished event
  def rebuild_framework_projection(framework, publish_event) # rubocop:disable Metrics/MethodLength
    framework_id = framework.framework_id

    destroy_framework_children(framework)

    framework.update!(
      current_published_version: publish_event.data[:version],
      draft_in_progress: false,
      draft_version: nil
    )

    stream = EventStreamNaming.framework_stream(framework_id)
    event_store = Rails.configuration.event_store
    event_store.read.stream(stream).each do |event|
      next if skip_during_rebuild?(event)

      handle(event)
    end
  end

  def skip_during_rebuild?(event)
    event.is_a?(Frameworks::Events::FrameworkCreated) ||
      event.is_a?(Frameworks::Events::DraftVersionStarted) ||
      event.is_a?(Frameworks::Events::FrameworkVersionPublished) ||
      event.is_a?(Frameworks::Events::MigrationMappingDefined) ||
      suggestion_event?(event)
  end

  # Suggestion events are an orthogonal concern from structural framework
  # state and their read models (FrameworkState::SuggestedEdit) are not
  # destroyed by destroy_framework_children. Replaying them on rebuild
  # would either trip unique-constraint violations on the create-style
  # events or be no-op idempotent updates on the state-transition events.
  # Skipping the entire family keeps suggestion lifecycle independent of
  # framework version rebuilds.
  SUGGESTION_EVENT_CLASSES = [
    Frameworks::Events::EditSuggested,
    Frameworks::Events::EntityCreationSuggested,
    Frameworks::Events::EntityDeletionSuggested,
    Frameworks::Events::SuggestionAmended,
    Frameworks::Events::SuggestionApproved,
    Frameworks::Events::SuggestionRejected,
    Frameworks::Events::SuggestionWithdrawn,
    Frameworks::Events::SuggestionCommented
  ].freeze

  def suggestion_event?(event)
    SUGGESTION_EVENT_CLASSES.any? { |klass| event.is_a?(klass) }
  end

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
    FrameworkState::Collaborator.where(framework_id: framework_id).delete_all
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

  # Dependent-editorial: parent Level is added via the shape-changing
  # LevelAdded event, which may be draft-deferred. If the Level row isn't
  # present yet, skip — the rebuild replay will re-apply this update after
  # LevelAdded lands.
  def handle_level_updated(event)
    record = FrameworkState::Level.find_by(level_id: event.data[:level_id])
    return unless record

    attrs = event.data.slice(:title, :code, :is_entry).compact
    record.update!(attrs) if attrs.any?
  end

  def handle_level_ordinal_changed(event)
    record = FrameworkState::Level.find_by!(level_id: event.data[:level_id])
    record.update!(ordinal: event.data[:new_ordinal])
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

  # Dependent-editorial: parent Capability is added via the shape-changing
  # CapabilityAdded event, which may be draft-deferred. If the Capability
  # row isn't present yet, skip — the rebuild replay will re-apply this
  # update after CapabilityAdded lands.
  def handle_capability_updated(event)
    record = FrameworkState::Capability.find_by(capability_id: event.data[:capability_id])
    return unless record

    attrs = event.data.slice(:name, :description).compact
    record.update!(attrs) if attrs.any?
  end

  def handle_binding_created(event)
    FrameworkState::CapabilityRoleBinding.create!(
      binding_id: event.data[:binding_id],
      capability_id: event.data[:capability_id],
      role_id: event.data[:role_id],
      weight: event.data[:weight],
      deficit_threshold: event.data[:individual_tolerance]  # maps legacy field to unified threshold
    )
  end

  # Dependent-editorial: parent binding is added via shape-changing
  # CapabilityRoleBindingCreated, which may be draft-deferred. Skip if absent.
  def handle_binding_updated(event)
    record = FrameworkState::CapabilityRoleBinding.find_by(binding_id: event.data[:binding_id])
    return unless record

    attrs = event.data.slice(:weight)
    attrs[:deficit_threshold] = event.data[:individual_tolerance] if event.data.key?(:individual_tolerance)
    record.update!(attrs) if attrs.any?
  end

  def handle_scoring_thresholds_configured(event)
    framework = find_framework(event)
    attrs = {}
    attrs[:mastery_threshold] = event.data[:mastery_threshold] if event.data.key?(:mastery_threshold)
    attrs[:meeting_expectation_threshold] = event.data[:promotion_score_threshold] if event.data.key?(:promotion_score_threshold)
    attrs[:overperformance_cap] = event.data[:overperformance_cap] if event.data.key?(:overperformance_cap)
    attrs[:deficit_threshold] = event.data[:deficit_threshold] if event.data.key?(:deficit_threshold)
    framework&.update!(attrs) if attrs.any?
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

  # Dependent-editorial: parent expectation is added via shape-changing
  # BehaviouralExpectationSet, which may be draft-deferred. Skip if absent.
  def handle_expectation_updated(event)
    record = FrameworkState::BehaviouralExpectation.find_by(expectation_id: event.data[:expectation_id])
    return unless record

    record.update!(description: event.data[:new_description])
  end

  # Dependent-editorial: illustrations reference a BehaviouralExpectation
  # (shape-changing) as their parent. If the expectation row is not yet in
  # the read model (because BehaviouralExpectationSet is still draft-deferred),
  # skip — the rebuild replay will re-apply this event in the correct order.
  def handle_illustration_added(event)
    return unless FrameworkState::BehaviouralExpectation
      .exists?(expectation_id: event.data[:expectation_id])

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
    record = FrameworkState::RoleIllustration.find_by(illustration_id: event.data[:illustration_id])
    return unless record

    record.update!(description: event.data[:new_description])
  end

  def handle_illustration_removed(event)
    record = FrameworkState::RoleIllustration.find_by(illustration_id: event.data[:illustration_id])
    record&.destroy!
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
      kind: "edit",
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

  def handle_entity_creation_suggested(event) # rubocop:disable Metrics/MethodLength
    FrameworkState::SuggestedEdit.create!(
      framework_id: event.data[:framework_id],
      suggestion_id: event.data[:suggestion_id],
      kind: "create",
      target_entity_type: event.data[:target_entity_type],
      proposed_attributes: event.data[:proposed_attributes] || {},
      parent_id: event.data[:parent_id],
      author_id: event.data[:author_id],
      rationale: event.data[:rationale],
      status: "pending"
    )
  end

  def handle_entity_deletion_suggested(event) # rubocop:disable Metrics/MethodLength
    entity_type = event.data[:target_entity_type]
    entity_id = event.data[:target_entity_id]
    FrameworkState::SuggestedEdit.create!(
      framework_id: event.data[:framework_id],
      suggestion_id: event.data[:suggestion_id],
      kind: "delete",
      target_entity_type: entity_type,
      target_entity_id: entity_id,
      current_value: snapshot_entity_summary(entity_type, entity_id),
      author_id: event.data[:author_id],
      rationale: event.data[:rationale],
      status: "pending"
    )
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
    record = lookup_entity(entity_type, entity_id)
    record&.public_send(field)
  end

  # Returns a brief human-readable summary of an entity for delete-suggestion
  # snapshots. The review UI uses this to show "what's about to be deleted"
  # without having to re-resolve the entity.
  #
  # @param entity_type [String]
  # @param entity_id [String]
  # @return [String, nil]
  def snapshot_entity_summary(entity_type, entity_id)
    record = lookup_entity(entity_type, entity_id)
    return nil unless record

    case entity_type
    when "role_illustration", "behavioural_expectation"
      record.description
    else
      record.respond_to?(:name) ? record.name : record.try(:title)
    end
  end

  # Resolves an entity read-model record by type + id.
  #
  # @param entity_type [String]
  # @param entity_id [String]
  # @return [ApplicationRecord, nil]
  def lookup_entity(entity_type, entity_id) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength
    case entity_type
    when "role_illustration"
      FrameworkState::RoleIllustration.find_by(illustration_id: entity_id)
    when "behavioural_expectation"
      FrameworkState::BehaviouralExpectation.find_by(expectation_id: entity_id)
    when "capability"
      FrameworkState::Capability.find_by(capability_id: entity_id)
    when "capability_category"
      FrameworkState::CapabilityCategory.find_by(category_id: entity_id)
    when "role"
      FrameworkState::Role.find_by(role_id: entity_id)
    when "role_family"
      FrameworkState::RoleFamily.find_by(role_family_id: entity_id)
    when "level"
      FrameworkState::Level.find_by(level_id: entity_id)
    end
  end

  # ── Collaborator handlers ──

  def handle_collaborator_added(event)
    FrameworkState::Collaborator.create!(
      framework_id: event.data[:framework_id],
      person_id: event.data[:person_id],
      role: event.data[:collaborator_role],
      scope_type: event.data[:scope_type],
      scope_id: event.data[:scope_id]
    )
  end

  def handle_collaborator_role_changed(event)
    record = FrameworkState::Collaborator.find_by!(
      framework_id: event.data[:framework_id],
      person_id: event.data[:person_id],
      role: event.data[:old_role],
      scope_type: event.data[:scope_type],
      scope_id: event.data[:scope_id]
    )
    record.update!(role: event.data[:new_role])
  end

  def handle_collaborator_removed(event)
    FrameworkState::Collaborator.find_by!(
      framework_id: event.data[:framework_id],
      person_id: event.data[:person_id],
      role: event.data[:collaborator_role],
      scope_type: event.data[:scope_type],
      scope_id: event.data[:scope_id]
    ).destroy!
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
