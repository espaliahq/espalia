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
                     keyword_init: true)

  # Event class → feed kind string. Drives both which events become feed
  # entries and the kind the view renders. Events not in this map (e.g.
  # FrameworkCreated, ScoringThresholdsConfigured, role/level structural
  # events) are deliberately out of the first increment's scope.
  KINDS = {
    Frameworks::Events::EditSuggested              => "suggestion_edit",
    Frameworks::Events::EntityCreationSuggested    => "suggestion_create",
    Frameworks::Events::EntityDeletionSuggested    => "suggestion_delete",
    Frameworks::Events::SuggestionAmended          => "suggestion_amended",
    Frameworks::Events::SuggestionApproved         => "suggestion_approved",
    Frameworks::Events::SuggestionRejected         => "suggestion_rejected",
    Frameworks::Events::SuggestionWithdrawn        => "suggestion_withdrawn",
    Frameworks::Events::DraftVersionStarted        => "draft_opened",
    Frameworks::Events::FrameworkVersionPublished  => "version_published",
    Frameworks::Events::MigrationMappingDefined    => "migration_mapping_defined",
    Frameworks::Events::CapabilityAdded            => "capability_added",
    Frameworks::Events::CapabilityArchived         => "capability_archived",
    Frameworks::Events::CapabilityUpdated          => "capability_updated",
    Frameworks::Events::CapabilityCategoryAdded    => "category_added",
    Frameworks::Events::CapabilityCategoryArchived => "category_archived",
    Frameworks::Events::CapabilityCategoryUpdated  => "category_updated",
    Frameworks::Events::BehaviouralExpectationUpdated => "expectation_updated",
    Frameworks::Events::RoleIllustrationAdded      => "illustration_added",
    Frameworks::Events::RoleIllustrationUpdated    => "illustration_updated",
    Frameworks::Events::RoleIllustrationRemoved    => "illustration_removed",
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
  ].freeze

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
    "suggestion_approved"      => :reviewer_id,
    "suggestion_rejected"      => :reviewer_id,
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
    @limit ? entries.first(@limit) : entries
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
      actor_name: actor_names[actor_id_for(event, kind)],
      category_id: category_id,
      capability_id: capability_id,
      capability_name: capability_name_for(capability_id),
      suggestion_id: suggestion_id,
      suggestion_status: meta&.dig(:suggestion_status),
      suggestion_entity_type: meta&.dig(:suggestion_entity_type)
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
    extra
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
    when "category_added", "category_archived", "category_updated"
      { capability_id: nil, category_id: data[:category_id] }
    when "expectation_updated"
      from_capability(expectation_to_capability[data[:expectation_id]])
    when "illustration_added"
      from_capability(expectation_to_capability[data[:expectation_id]])
    when "illustration_updated", "illustration_removed"
      from_capability(expectation_to_capability[illustration_to_expectation[data[:illustration_id]]])
    else
      # draft_opened, version_published, migration_mapping_defined,
      # collaborator_* — framework-level, no matrix anchor.
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

  # {Person id => name} for every actor referenced by a feed entry on this
  # stream. Loaded in one query and memoised so per-entry resolution never
  # N+1s. Non-UUID sentinels (e.g. the bootstrap draft's `started_by: "system"`)
  # are filtered out so the uuid-typed lookup never raises.
  def actor_names
    @actor_names ||= begin
      ids = stream_events.filter_map do |event|
        kind = KINDS[event.class]
        actor_id_for(event, kind) if kind
      end.uniq.select { |id| id.to_s.match?(UUID_FORMAT) }
      ids.empty? ? {} : Person.where(id: ids).pluck(:id, :name).to_h
    end
  end

  # ── Structure maps (built once from the framework read model) ──

  def preloaded_categories
    @preloaded_categories ||= @framework.capability_categories
      .includes(capabilities: { expectations: :illustrations }).to_a
  end

  def all_capabilities
    @all_capabilities ||= preloaded_categories.flat_map(&:capabilities)
  end

  def capability_to_category
    @capability_to_category ||= all_capabilities.to_h { |c| [ c.capability_id, c.category_id ] }
  end

  def capability_names
    @capability_names ||= all_capabilities.to_h { |c| [ c.capability_id, c.name ] }
  end

  def category_names
    @category_names ||= preloaded_categories.to_h { |c| [ c.category_id, c.name ] }
  end

  def expectation_to_capability
    @expectation_to_capability ||= all_capabilities.flat_map(&:expectations)
      .to_h { |e| [ e.expectation_id, e.capability_id ] }
  end

  def illustration_to_expectation
    @illustration_to_expectation ||= all_capabilities
      .flat_map(&:expectations).flat_map(&:illustrations)
      .to_h { |i| [ i.illustration_id, i.expectation_id ] }
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
          suggestion_status: s.status } ]
    end
  end

  def suggested_edits
    @suggested_edits ||= @framework.suggested_edits.to_a
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
