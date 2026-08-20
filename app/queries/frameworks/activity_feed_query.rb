# frozen_string_literal: true

# Loads the activity feed for a framework — a unified, reverse-chronological
# stream of typed entries the explorer's right-hand context pane renders.
#
# The feed generalises the old suggestions-only panel into the framework's
# full audit trail: the suggestion lifecycle (submitted / amended / approved /
# rejected / withdrawn), the draft & version lifecycle (draft opened, version
# published, migration mapping defined), structural changes (capability /
# category add · archive), editorial edits (capability / category / expectation
# / illustration updated), and collaborator changes (added / role changed /
# removed). See docs/guidelines/framework-explorer.md → "Activity feed coverage".
#
# Source: the framework's RES stream
# (`EventStreamNaming.framework_stream(framework_id)`), read chronologically.
#
# Anchoring & focus: each entry is anchored to the `(category_id, capability_id)`
# it concerns where resolvable. The optional `focus / category_id /
# capability_id / level_ordinal` narrows the feed exactly like
# {Frameworks::FocusedSuggestionsQuery} narrows the suggestion list — framework
# focus shows everything, narrower focus filters by anchor. Framework-level
# events (draft / version / collaborator) carry nil anchors and surface only at
# framework focus.
#
# Visibility: framework collaborators with view rights see all framework
# activity — there is no per-person privacy gate like the assessment feed.
#
class Frameworks::ActivityFeedQuery
  Entry = Struct.new(:id, :kind, :occurred_at, :payload, :actor_name,
                     :category_id, :capability_id, :capability_name,
                     :suggestion_id, :suggestion_status, :suggestion_entity_type,
                     :superseded, :comment_count, :latest_comment,
                     keyword_init: true)

  # Proposal events for one suggestion (the original edit + each amendment).
  # Only the most recent of these carries the approve/reject action — see
  # #flag_superseded_proposals. Includes the original create/delete/edit proposal
  # plus each amendment, so amending a create supersedes the original proposal
  # entry (only the latest, with the current value, stays actionable).
  PROPOSAL_KINDS = %w[suggestion_edit suggestion_create suggestion_delete suggestion_amended].freeze

  # Event class → feed kind string. Drives both which events become feed
  # entries and the kind the view renders. Events not in this map (e.g.
  # FrameworkCreated, ScoringThresholdsConfigured) are deliberately out of
  # scope; org-structure *renames* (RoleFamilyUpdated / RoleUpdated /
  # LevelUpdated), *adds* (RoleFamilyAdded / RoleAdded / LevelAdded) and
  # *reorders* (RoleIllustrationReordered / CapabilityCategoryReordered /
  # CapabilityReordered) are covered.
  KINDS = {
    Frameworks::Events::EditSuggested              => "suggestion_edit",
    Frameworks::Events::EntityCreationSuggested    => "suggestion_create",
    Frameworks::Events::EntityDeletionSuggested    => "suggestion_delete",
    Frameworks::Events::SuggestionAmended          => "suggestion_amended",
    Frameworks::Events::SuggestionApproved         => "suggestion_approved",
    Frameworks::Events::SuggestionRejected         => "suggestion_rejected",
    Frameworks::Events::SuggestionWithdrawn        => "suggestion_withdrawn",
    Frameworks::Events::SuggestionCommented        => "suggestion_commented",
    Frameworks::Events::ClarificationRequested     => "clarification_requested",
    Frameworks::Events::ClarificationResolved      => "clarification_resolved",
    Frameworks::Events::DraftVersionStarted        => "draft_opened",
    Frameworks::Events::FrameworkVersionPublished  => "version_published",
    Frameworks::Events::MigrationMappingDefined    => "migration_mapping_defined",
    Frameworks::Events::CapabilityAdded            => "capability_added",
    Frameworks::Events::CapabilityArchived         => "capability_archived",
    Frameworks::Events::CapabilityUpdated          => "capability_updated",
    Frameworks::Events::CapabilityReordered        => "capability_reordered",
    Frameworks::Events::CapabilityCategoryAdded    => "category_added",
    Frameworks::Events::CapabilityCategoryArchived => "category_archived",
    Frameworks::Events::CapabilityCategoryUpdated  => "category_updated",
    Frameworks::Events::CapabilityCategoryReordered => "category_reordered",
    Frameworks::Events::CapabilityRoleBindingCreated => "binding_added",
    Frameworks::Events::CapabilityRoleBindingUpdated => "binding_updated",
    Frameworks::Events::CapabilityRoleBindingRemoved => "binding_removed",
    Frameworks::Events::BehaviouralExpectationSet     => "expectation_added",
    Frameworks::Events::BehaviouralExpectationUpdated => "expectation_updated",
    Frameworks::Events::RoleIllustrationAdded      => "illustration_added",
    Frameworks::Events::RoleIllustrationUpdated    => "illustration_updated",
    Frameworks::Events::RoleIllustrationRemoved    => "illustration_removed",
    Frameworks::Events::RoleIllustrationReordered  => "illustration_reordered",
    Frameworks::Events::RoleFamilyUpdated          => "role_family_updated",
    Frameworks::Events::RoleUpdated                => "role_updated",
    Frameworks::Events::LevelUpdated               => "level_updated",
    Frameworks::Events::RoleFamilyAdded            => "role_family_added",
    Frameworks::Events::RoleAdded                  => "role_added",
    Frameworks::Events::LevelAdded                 => "level_added",
    Frameworks::Events::CollaboratorAdded          => "collaborator_added",
    Frameworks::Events::CollaboratorRoleChanged    => "collaborator_role_changed",
    Frameworks::Events::CollaboratorRemoved        => "collaborator_removed"
  }.freeze

  # Suggestion lifecycle kinds — anchored via the SuggestedEdit read model
  # (the resolved/withdrawn events carry only the suggestion_id, so the
  # target entity is resolved by suggestion_id, not from the event payload).
  SUGGESTION_KINDS = %w[
    suggestion_edit suggestion_create suggestion_delete
    suggestion_amended suggestion_approved suggestion_rejected suggestion_withdrawn
    suggestion_commented clarification_requested clarification_resolved
  ].freeze

  # Binding lifecycle kinds — their entries carry the role + scoring levers
  # (weight / individual tolerance) folded into the payload by #binding_metadata.
  BINDING_KINDS = %w[binding_added binding_updated binding_removed].freeze

  # Collaborator lifecycle kinds — their entries name the collaborator the
  # action concerns (`collaborator_name`, resolved from the event's person_id),
  # not just the acting admin in the footer.
  COLLABORATOR_KINDS = %w[collaborator_added collaborator_role_changed collaborator_removed].freeze

  # Directly-authored / edited expectation kinds — their entries carry the level
  # (`expectation_level`) folded in by #structural_expectation_level. (Expectation
  # *suggestions* get the level via #suggestion_meta instead.)
  EXPECTATION_KINDS = %w[expectation_added expectation_updated].freeze

  # Direct illustration edits — their entries carry the level + role the
  # illustration belongs to (`expectation_level` / `illustration_role_label`),
  # folded in by #illustration_metadata. (Illustration *suggestions* get the
  # same context via #suggestion_meta; reorders keep their role-in-summary.)
  ILLUSTRATION_KINDS = %w[illustration_added illustration_updated illustration_removed].freeze

  # Maps each feed kind to the payload key carrying its actor's Person id, when
  # the actor is a first-class payload fact. Kinds absent here fall back to
  # `event.metadata[:actor_id]` (the universal provenance stamp) — that covers
  # every structural / lifecycle / editorial event, whose actor lives only in
  # metadata. nil-safe throughout: historical / system events resolve to no
  # name and the view renders a generic label.
  ACTOR_PAYLOAD_KEYS = {
    "suggestion_edit"          => :author_id,
    "suggestion_create"        => :author_id,
    "suggestion_delete"        => :author_id,
    "suggestion_amended"       => :author_id,
    "suggestion_commented"     => :author_id,
    "suggestion_approved"      => :reviewer_id,
    "suggestion_rejected"      => :reviewer_id,
    "clarification_requested"  => :author_id,
    "clarification_resolved"   => :resolver_id,
    "draft_opened"             => :started_by,
    "version_published"        => :published_by,
    "collaborator_added"       => :added_by,
    "collaborator_role_changed" => :changed_by,
    "collaborator_removed"     => :removed_by
  }.freeze

  FOCUS_LEVELS = %i[framework category capability cell].freeze

  # Upper bound on how many of the most-recent stream events the feed reads.
  # Keeps each reload O(cap), not O(framework history). See #stream_events for
  # the recency trade-off. ~250 comfortably covers a panel's worth of recent
  # activity (the panel is scrollable but not infinite).
  STREAM_READ_LIMIT = 250

  UUID_FORMAT = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  # @param framework [FrameworkState::Framework]
  # @param focus [Symbol] one of FOCUS_LEVELS (default :framework)
  # @param category_id [String, nil]
  # @param capability_id [String, nil]
  # @param level_ordinal [Integer, nil] accepted for URL parity; the feed
  #   anchors at capability granularity, so cell focus narrows by capability
  # @param limit [Integer, nil] cap on the number of (most-recent) entries
  #   returned; nil returns the full feed (the explorer panel's default)
  # @param before [String, nil] cursor — an event id; reads the batch of events
  #   *older* than it (the "load older activity" pagination). nil reads the most
  #   recent batch.
  # @param event_store [RailsEventStore::Client] override for tests
  def initialize(framework:, focus: :framework, category_id: nil,
                 capability_id: nil, level_ordinal: nil, limit: nil, before: nil,
                 event_store: Rails.configuration.event_store)
    @framework = framework
    @category_id = category_id
    @capability_id = capability_id
    @level_ordinal = level_ordinal
    @limit = limit
    @before = before
    @focus = resolve_focus(focus, category_id: category_id, capability_id: capability_id)
    @event_store = event_store
  end

  # @return [Array<Entry>] reverse-chronological entries (capped at `limit`)
  def call
    entries = stream_events.filter_map { |event| build_entry(event) }
    entries.select! { |entry| match_focus?(entry) }
    entries.sort_by! { |entry| entry.occurred_at || Time.at(0) }
    entries.reverse!
    flag_superseded_proposals(entries)
    @limit ? entries.first(@limit) : entries
  end

  # Flags every proposal entry (edit / amendment) that has been superseded by a
  # more recent proposal on the same suggestion, so the approve/reject action
  # lands only on the latest one — approving an out-of-date proposal is
  # pointless. `entries` is newest-first here, so the first proposal seen per
  # suggestion_id is the live one and the rest are superseded. (An amendment is
  # always newer than its original edit, so the two arrive together in the same
  # recent batch; the marking is therefore correct for the cases that matter.)
  #
  # @param entries [Array<Entry>] newest-first
  # @return [void]
  def flag_superseded_proposals(entries)
    seen = Set.new
    entries.each do |entry|
      next unless entry.suggestion_id && PROPOSAL_KINDS.include?(entry.kind)

      entry.superseded = true unless seen.add?(entry.suggestion_id)
    end
  end

  # Whether the stream holds events older than this batch — i.e. there is more
  # to load. Event-level (not entry-level): the panel only surfaces "load older"
  # at framework focus, where every event is a candidate entry.
  #
  # @return [Boolean]
  def has_more?
    read_result[:has_more]
  end

  # Cursor to pass as `before:` for the next (older) batch — the id of the
  # oldest event in this batch.
  #
  # @return [String, nil]
  def next_cursor
    read_result[:next_cursor]
  end

  # @return [Symbol] effective focus after validation
  attr_reader :focus

  # Human-readable descriptor for the panel header — mirrors
  # {Frameworks::FocusedSuggestionsQuery#descriptor}.
  #
  # @return [Hash] { level:, category_name:, capability_name:, level_label: }
  def descriptor
    case @focus
    when :category
      { level: :category, category_name: category_name_for(@category_id) }
    when :capability
      { level: :capability, capability_name: capability_name_for(@capability_id) }
    when :cell
      { level: :cell, capability_name: capability_name_for(@capability_id),
        level_label: "L#{@level_ordinal}" }
    else
      { level: :framework }
    end
  end

  private

  def build_entry(event)
    kind = KINDS[event.class]
    return nil unless kind

    data = event.data.with_indifferent_access
    anchor = anchor_for(kind, data)
    capability_id = anchor[:capability_id]
    category_id = anchor[:category_id]
    suggestion_id = data[:suggestion_id] if SUGGESTION_KINDS.include?(kind)
    meta = suggestion_id ? suggestion_meta[suggestion_id] : nil

    Entry.new(
      id: event.event_id,
      kind: kind,
      occurred_at: event_timestamp(event),
      payload: data.merge(entry_metadata(kind, data, capability_id, category_id)),
      actor_name: person_names[actor_id_for(event, kind)],
      category_id: category_id,
      capability_id: capability_id,
      capability_name: capability_name_for(capability_id),
      suggestion_id: suggestion_id,
      suggestion_status: meta&.dig(:suggestion_status),
      suggestion_entity_type: meta&.dig(:suggestion_entity_type),
      comment_count: suggestion_id ? comment_stats.dig(suggestion_id, :count) || 0 : 0,
      latest_comment: suggestion_id ? comment_stats.dig(suggestion_id, :latest_body) : nil
    )
  end

  # Display-name + suggestion-context fields folded into the payload so the
  # view stays a dumb renderer. Suggestion lifecycle events (approved /
  # rejected / withdrawn / amended) carry only a suggestion_id, so the entity
  # type + field are sourced from the SuggestedEdit read model here.
  def entry_metadata(kind, data, capability_id, category_id)
    extra = {}
    extra[:capability_name] = capability_name_for(capability_id) if capability_id
    extra[:category_name] = category_name_for(category_id) if category_id

    if SUGGESTION_KINDS.include?(kind)
      meta = suggestion_meta[data[:suggestion_id]]
      extra.merge!(meta) if meta
    end
    extra.merge!(binding_metadata(kind, data)) if BINDING_KINDS.include?(kind)
    if COLLABORATOR_KINDS.include?(kind)
      extra[:collaborator_name] = person_names[data[:person_id]]
    end
    if kind == "illustration_reordered" && role_labels.key?(data[:role_id])
      extra[:reorder_role_label] = role_labels[data[:role_id]]
    end
    if kind == "level_added" && role_labels.key?(data[:role_id])
      extra[:level_role_label] = role_labels[data[:role_id]]
    end
    if kind == "suggestion_commented"
      # The event payload's body is frozen history — render the read model's
      # CURRENT text instead, so an edited comment shows its latest wording
      # and a deleted comment's body disappears from the feed (the thread
      # shows a tombstone; the feed entry keeps only the fact of the action).
      extra[:body] = active_comment_bodies[data[:comment_id]]
    end
    extra[:expectation_level] = structural_expectation_level(kind, data) if EXPECTATION_KINDS.include?(kind)
    extra.merge!(illustration_metadata(data)) if ILLUSTRATION_KINDS.include?(kind)
    extra
  end

  # Level + role for a direct illustration edit — an illustration is a
  # (capability × level × role) artefact, so its entry locates all three
  # (the capability rides the anchor's context line). The added event carries
  # expectation_id + role_id; update/remove carry only the illustration_id and
  # resolve through the read-model maps.
  def illustration_metadata(data)
    expectation_id = data[:expectation_id] || illustration_to_expectation[data[:illustration_id]]
    role_id = data[:role_id] || illustration_to_role[data[:illustration_id]]
    meta = {}
    level = expectation_to_level[expectation_id]
    meta[:expectation_level] = level if level.present?
    meta[:illustration_role_label] = role_labels[role_id] if role_id && role_labels.key?(role_id)
    meta
  end

  # Level for a directly-authored / edited expectation entry (the suggestion
  # variants get it from suggestion_meta). expectation_added carries it on the
  # event; expectation_updated resolves it from the target expectation.
  def structural_expectation_level(kind, data)
    case kind
    when "expectation_added" then data[:level_ordinal]
    when "expectation_updated" then expectation_to_level[data[:expectation_id]]
    end
  end

  # Role label + the scoring levers a binding entry should surface — the role it
  # concerns (resolved from the payload, or the binding index for update/remove)
  # and the weight / individual tolerance carried by add & update payloads. An
  # update payload is `.compact`ed by the aggregate, so a present key means that
  # lever actually changed.
  def binding_metadata(kind, data)
    role_id = data[:role_id] || binding_index.dig(data[:binding_id], :role_id)
    meta = {}
    meta[:binding_role_label] = role_labels[role_id] if role_id && role_labels.key?(role_id)
    return meta if kind == "binding_removed"

    meta[:binding_weight] = data[:weight] unless data[:weight].nil?
    meta[:binding_individual_tolerance] = data[:individual_tolerance] unless data[:individual_tolerance].nil?
    meta
  end

  # ── Anchoring ──

  # @return [Hash] { capability_id:, category_id: } — either may be nil
  def anchor_for(kind, data)
    if SUGGESTION_KINDS.include?(kind)
      suggestion_anchors[data[:suggestion_id]] || empty_anchor
    else
      structural_anchor(kind, data)
    end
  end

  def structural_anchor(kind, data)
    case kind
    when "capability_added", "capability_archived", "capability_updated"
      from_capability(data[:capability_id])
    when "category_added", "category_archived", "category_updated", "capability_reordered"
      # capability_reordered touches every capability in the category, so it
      # anchors at the category, not any single capability.
      { capability_id: nil, category_id: data[:category_id] }
    when "binding_added"
      from_capability(data[:capability_id])
    when "binding_updated", "binding_removed"
      # The update/remove payloads carry only the binding_id; resolve the
      # capability via the binding index. A binding removed *and* published is
      # gone from the read model, so anchoring may fall back to framework-level.
      from_capability(binding_index.dig(data[:binding_id], :capability_id))
    when "expectation_added"
      # The set event carries capability_id directly.
      from_capability(data[:capability_id])
    when "expectation_updated"
      from_capability(expectation_to_capability[data[:expectation_id]])
    when "illustration_added", "illustration_reordered"
      from_capability(expectation_to_capability[data[:expectation_id]])
    when "illustration_updated", "illustration_removed"
      from_capability(expectation_to_capability[illustration_to_expectation[data[:illustration_id]]])
    else
      # draft_opened, version_published, migration_mapping_defined,
      # collaborator_*, category_reordered (touches every category) —
      # framework-level, no matrix anchor.
      empty_anchor
    end
  end

  def from_capability(capability_id)
    { capability_id: capability_id, category_id: capability_to_category[capability_id] }
  end

  def empty_anchor
    { capability_id: nil, category_id: nil }
  end

  # ── Focus ──

  def resolve_focus(focus, category_id:, capability_id:)
    focus = focus.to_sym if focus.respond_to?(:to_sym)
    return :framework unless FOCUS_LEVELS.include?(focus)

    case focus
    when :category               then category_id.present?   ? :category   : :framework
    when :capability, :cell      then capability_id.present? ? focus       : :framework
    else focus
    end
  end

  def match_focus?(entry)
    case @focus
    when :category          then entry.category_id == @category_id
    when :capability, :cell then entry.capability_id == @capability_id
    else true # :framework
    end
  end

  # ── Stream ──

  # Read only the most-recent slice of the stream, newest-first. The feed is a
  # recency-ordered narrative, so reading the whole stream is needless O(history)
  # work that dominates latency on a mature framework (a 1636-event framework
  # reads in ~240ms and builds 1000+ entries). Bounding the read to the most
  # recent STREAM_READ_LIMIT events makes every reload O(cap) instead.
  #
  # Trade-off: an activity older than the cap drops off the feed. Pending
  # suggestions older than the window are therefore not actionable *from the
  # feed* — but they remain visible (and approvable) on the matrix grid (the
  # inline diff is shown regardless of age) and on the standalone suggestion
  # index, so no review path is lost.
  def stream_events
    read_result[:events]
  end

  # Single backward read of the stream, newest-first, optionally from a cursor.
  # Reads one more than the batch size to detect whether older events remain
  # (cheaper than a separate count): if the read came back full+1, there's more,
  # and we keep the batch-sized slice. The cursor for the next batch is the
  # oldest event we keep.
  def read_result
    @read_result ||= begin
      scope = @event_store.read
        .stream(EventStreamNaming.framework_stream(@framework.framework_id))
        .backward
      scope = scope.from(@before) if @before
      raw = scope.limit(read_limit + 1).to_a

      events = raw.first(read_limit)
      { events: events, has_more: raw.size > read_limit, next_cursor: events.last&.event_id }
    end
  end

  # How many of the most-recent events to read per batch. Never less than the
  # requested display `limit` (so a caller asking for N most-recent always gets N).
  def read_limit
    [ @limit.to_i, STREAM_READ_LIMIT ].max
  end

  def event_timestamp(event)
    event.metadata[:timestamp] || (event.respond_to?(:timestamp) ? event.timestamp : nil)
  end

  # ── Actor resolution ──

  def actor_id_for(event, kind)
    data = event.data
    payload_key = ACTOR_PAYLOAD_KEYS[kind]
    payload_actor = payload_key && (data[payload_key] || data[payload_key.to_s])
    payload_actor.presence || event.metadata[:actor_id]
  end

  # {Person id => name} for every person a feed entry references — actors
  # (footer attribution) plus the collaborator a collaborator-lifecycle event
  # concerns. Loaded in one query and memoised so per-entry resolution never
  # N+1s. Non-UUID sentinels (e.g. the bootstrap draft's `started_by: "system"`)
  # are filtered out so the uuid-typed lookup never raises.
  def person_names
    @person_names ||= begin
      ids = stream_events.flat_map do |event|
        kind = KINDS[event.class]
        next [] unless kind

        referenced = [ actor_id_for(event, kind) ]
        referenced << event.data[:person_id] if COLLABORATOR_KINDS.include?(kind)
        referenced
      end.compact.uniq.select { |id| id.to_s.match?(UUID_FORMAT) }
      ids.empty? ? {} : Person.where(id: ids).pluck(:id, :name).to_h
    end
  end

  # ── Structure maps (read model + draft-entity supplement) ──
  #
  # The published read model excludes shape-changing entities still in the open
  # draft (added capability / category / expectation). The feed must still name
  # them, so each map is supplemented from the creating event in the read window
  # — the same recency-bounded approach #binding_index uses. Read-model values
  # win (authoritative for published entities); the supplement only fills gaps.

  def preloaded_categories
    @preloaded_categories ||= @framework.capability_categories
      .includes(capabilities: { expectations: :illustrations }).to_a
  end

  def all_capabilities
    @all_capabilities ||= preloaded_categories.flat_map(&:capabilities)
  end

  # Names/coordinates of draft-added entities, harvested from the stream window.
  # `stream_events` is newest-first, so `||=` keeps the most-recent value — a
  # draft-added entity renamed before publish (its rename is also absent from the
  # published read model) shows its current name, not the original.
  def stream_structure
    @stream_structure ||= begin
      acc = { cap_names: {}, cap_to_cat: {}, cat_names: {}, exp_to_cap: {}, exp_to_level: {} }
      stream_events.each do |event|
        case event
        when Frameworks::Events::CapabilityAdded
          acc[:cap_names][event.data[:capability_id]] ||= event.data[:name]
          acc[:cap_to_cat][event.data[:capability_id]] ||= event.data[:category_id]
        when Frameworks::Events::CapabilityUpdated
          acc[:cap_names][event.data[:capability_id]] ||= event.data[:name] if event.data.key?(:name)
        when Frameworks::Events::CapabilityCategoryAdded
          acc[:cat_names][event.data[:category_id]] ||= event.data[:name]
        when Frameworks::Events::CapabilityCategoryUpdated
          acc[:cat_names][event.data[:category_id]] ||= event.data[:name] if event.data.key?(:name)
        when Frameworks::Events::BehaviouralExpectationSet
          acc[:exp_to_cap][event.data[:expectation_id]] ||= event.data[:capability_id]
          acc[:exp_to_level][event.data[:expectation_id]] ||= event.data[:level_ordinal]
        end
      end
      acc
    end
  end

  def capability_to_category
    @capability_to_category ||= stream_structure[:cap_to_cat]
      .merge(all_capabilities.to_h { |c| [ c.capability_id, c.category_id ] })
  end

  def capability_names
    @capability_names ||= stream_structure[:cap_names]
      .merge(all_capabilities.to_h { |c| [ c.capability_id, c.name ] })
  end

  def category_names
    @category_names ||= stream_structure[:cat_names]
      .merge(preloaded_categories.to_h { |c| [ c.category_id, c.name ] })
  end

  def expectation_to_capability
    @expectation_to_capability ||= stream_structure[:exp_to_cap]
      .merge(all_capabilities.flat_map(&:expectations).to_h { |e| [ e.expectation_id, e.capability_id ] })
  end

  # {expectation_id => level_ordinal} — read model + draft supplement.
  def expectation_to_level
    @expectation_to_level ||= stream_structure[:exp_to_level]
      .merge(all_capabilities.flat_map(&:expectations).to_h { |e| [ e.expectation_id, e.level_ordinal ] })
  end

  def illustration_to_expectation
    @illustration_to_expectation ||= all_capabilities
      .flat_map(&:expectations).flat_map(&:illustrations)
      .to_h { |i| [ i.illustration_id, i.expectation_id ] }
  end

  # {illustration_id => role_id} — so illustration entries can name the role
  # they illustrate for.
  def illustration_to_role
    @illustration_to_role ||= all_capabilities
      .flat_map(&:expectations).flat_map(&:illustrations)
      .to_h { |i| [ i.illustration_id, i.role_id ] }
  end

  # {binding_id => { capability_id:, role_id: }}. Built from the read model
  # (covers every binding still present — incl. ones updated live, or
  # removed-but-not-yet-published) and supplemented from CapabilityRoleBindingCreated
  # events in the read window (so a binding both created and removed-then-published
  # within the window still resolves its capability + role). A binding created
  # before the window and later removed falls back to a framework-level anchor and
  # no role label — consistent with the recency model.
  def binding_index
    @binding_index ||= begin
      cap_ids = all_capabilities.map(&:capability_id)
      rows = cap_ids.empty? ? [] : FrameworkState::CapabilityRoleBinding
        .where(capability_id: cap_ids).pluck(:binding_id, :capability_id, :role_id)
      map = rows.to_h { |bid, cid, rid| [ bid, { capability_id: cid, role_id: rid } ] }
      stream_events.each do |event|
        next unless event.is_a?(Frameworks::Events::CapabilityRoleBindingCreated)

        map[event.data[:binding_id]] ||= { capability_id: event.data[:capability_id],
                                           role_id: event.data[:role_id] }
      end
      map
    end
  end

  # {role_id => "CODE · Name"} for every role in the framework, so binding feed
  # entries can name the role they bound / unbound / reweighted.
  def role_labels
    @role_labels ||= begin
      family_ids = FrameworkState::RoleFamily.where(framework_id: @framework.framework_id).pluck(:role_family_id)
      FrameworkState::Role.where(role_family_id: family_ids)
        .pluck(:role_id, :code, :name)
        .to_h { |rid, code, name| [ rid, [ code, name ].compact.join(" · ") ] }
    end
  end

  def capability_name_for(capability_id)
    capability_id && capability_names[capability_id]
  end

  def category_name_for(category_id)
    category_id && category_names[category_id]
  end

  # ── Suggestion lookups ──

  # {suggestion_id => { capability_id:, category_id: }} for every suggestion on
  # the framework, so the resolved/withdrawn lifecycle events (which carry only
  # the suggestion_id) can be anchored to the entity they concern.
  def suggestion_anchors
    @suggestion_anchors ||= suggested_edits.to_h do |s|
      [ s.suggestion_id, suggestion_anchor(s) ]
    end
  end

  # {suggestion_id => { entity_type:, kind:, field:, status: }} so the view can
  # describe a resolved suggestion ("Approved an edit to Capability description")
  # without re-deriving it from the (absent) lifecycle-event payload, and decide
  # whether a still-pending suggestion is actionable (status + entity tier).
  def suggestion_meta
    @suggestion_meta ||= suggested_edits.to_h do |s|
      [ s.suggestion_id,
        { suggestion_entity_type: s.target_entity_type,
          suggestion_kind: s.kind,
          suggestion_field: s.field,
          suggestion_status: s.status,
          expectation_level: suggestion_level(s),
          suggestion_role_label: suggestion_role_label(s) } ]
    end
  end

  # The level a suggestion concerns, so the feed entry can show
  # "Capability · L<n>": proposed_attributes carries it for expectation
  # creates AND capability-anchored clarifications; an expectation-targeting
  # edit/delete/clarification resolves it from the target expectation; an
  # illustration suggestion resolves it through its parent expectation. nil
  # for everything else.
  def suggestion_level(suggestion)
    from_attrs = suggestion.proposed_attributes&.dig("level_ordinal")
    return from_attrs.to_i if from_attrs.present?

    case suggestion.target_entity_type
    when "behavioural_expectation"
      expectation_to_level[suggestion.target_entity_id]
    when "role_illustration"
      expectation_to_level[illustration_suggestion_expectation_id(suggestion)]
    end
  end

  # The role an illustration suggestion concerns ("CODE · Name"), so its feed
  # entry can locate the (capability × level × role) cell it proposes into.
  # nil for every other entity type, and for history whose role no longer
  # resolves.
  def suggestion_role_label(suggestion)
    return nil unless suggestion.target_entity_type == "role_illustration"

    role_id =
      if suggestion.kind == "create"
        suggestion.proposed_attributes&.dig("role_id")
      else
        illustration_to_role[suggestion.target_entity_id]
      end
    role_id && role_labels[role_id]
  end

  # A create's parent IS the expectation; an edit/delete resolves through the
  # existing illustration.
  def illustration_suggestion_expectation_id(suggestion)
    if suggestion.kind == "create"
      suggestion.parent_id
    else
      illustration_to_expectation[suggestion.target_entity_id]
    end
  end

  def suggested_edits
    @suggested_edits ||= @framework.suggested_edits.to_a
  end

  # The framework's ACTIVE thread comments, loaded once (only the columns
  # the feed needs — a body-bearing full-row load would grow with all-time
  # comment volume) and shared by the two derived maps below.
  def thread_comments
    @thread_comments ||= FrameworkState::SuggestionComment.active
      .for_framework(@framework.framework_id)
      .order(:posted_at)
      .select(:id, :suggestion_id, :body, :posted_at)
      .to_a
  end

  # {suggestion_id => { count:, latest_body: }} — powers the discussion
  # affordance (count + latest excerpt) on every suggestion-anchored entry.
  def comment_stats
    @comment_stats ||= thread_comments.group_by(&:suggestion_id)
      .transform_values { |comments| { count: comments.size, latest_body: comments.last.body } }
  end

  # {comment_id => current body} for active comments — the read-model
  # overlay for suggestion_commented entries (nil for deleted comments).
  def active_comment_bodies
    @active_comment_bodies ||= thread_comments.to_h { |c| [ c.id, c.body ] }
  end

  def suggestion_anchor(suggestion)
    case suggestion.target_entity_type
    when "role_illustration"
      exp_id = suggestion.kind == "create" ? suggestion.parent_id : illustration_to_expectation[suggestion.target_entity_id]
      from_capability(expectation_to_capability[exp_id])
    when "behavioural_expectation"
      cap_id = suggestion.kind == "create" ? suggestion.parent_id : expectation_to_capability[suggestion.target_entity_id]
      from_capability(cap_id)
    when "capability"
      if suggestion.kind == "create"
        { capability_id: nil, category_id: suggestion.parent_id }
      else
        from_capability(suggestion.target_entity_id)
      end
    when "capability_category"
      { capability_id: nil, category_id: (suggestion.kind == "create" ? nil : suggestion.target_entity_id) }
    else
      # role, role_family, level — framework-level, no matrix anchor.
      empty_anchor
    end
  end
end
