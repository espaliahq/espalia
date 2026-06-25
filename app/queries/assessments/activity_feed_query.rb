# frozen_string_literal: true

# Loads the activity feed for an assessment — a unified, reverse-chronological
# stream of typed entries that the right-hand sidebar renders.
#
# Sources:
# - PersonDevelopment events read from the per-(person, framework) RES
#   stream. Captures every rating change (self / manager / aligned) with
#   the timestamp the event was emitted.
# - {EvidenceItem} rows for evidence-recorded and evidence-withdrawn
#   entries (the origin link is the recorded entry).
# - `EvidenceLinkAdded` / `EvidenceLinkRemoved` events from the same RES
#   stream for the multi-linkage `evidence_linked` / `evidence_unlinked`
#   entries (a single item attached to / detached from additional cells).
# - {AssessmentCycleProgress} rows for alignment milestones
#   (`alignment_started_at`, `aligned_at`).
#
# Visibility:
# - When `viewer_sees_all == false` (peer): omit manager-rating events
#   entirely, and filter evidence to items the viewer authored.
# - When `viewer_sees_all == true` and `context == :self` and alignment
#   has not yet started, manager-rating events are also hidden — same
#   privacy gate as the matrix's `hide_others?` so the assessee never
#   sees their manager's calibration before alignment formally begins.
#
class Assessments::ActivityFeedQuery
  Entry = Struct.new(:id, :kind, :occurred_at, :payload, :capability_stable_id,
                     :level_ordinal, :cycle_id, :capability_name, :category_id,
                     keyword_init: true)

  RATING_KINDS = {
    PersonDevelopment::Events::SelfRated              => "self_rated",
    PersonDevelopment::Events::SelfRatingRevised      => "self_rating_revised",
    PersonDevelopment::Events::SelfRatingCleared      => "self_rating_cleared",
    PersonDevelopment::Events::ManagerRated           => "manager_rated",
    PersonDevelopment::Events::ManagerRatingRevised   => "manager_rating_revised",
    PersonDevelopment::Events::ManagerRatingCleared   => "manager_rating_cleared",
    PersonDevelopment::Events::AssessmentAligned      => "assessment_aligned",
    PersonDevelopment::Events::AlignmentCleared       => "alignment_cleared"
  }.freeze

  # Evidence relinks live on the same RES stream as ratings — they're
  # an event, not a column on the read model — so we read them from
  # the stream alongside rating events. The feed renders them as their
  # own entry kind (with from→to coords) rather than amending the
  # original `evidence_recorded` entry.
  RELINK_KIND = "evidence_relinked"

  # Multi-linkage: a single piece of evidence can be attached to / detached
  # from additional (capability, level) cells after it's recorded. These
  # live on the RES stream as `EvidenceLinkAdded` / `EvidenceLinkRemoved`
  # events (the first link is part of `evidence_recorded`), so the feed
  # reads them from the stream like relinks. Rendered under the Evidence
  # filter.
  LINK_ADDED_KIND   = "evidence_linked"
  LINK_REMOVED_KIND = "evidence_unlinked"

  # Per-capability re-keying entry — emitted for every mapping in a
  # `FrameworkVersionMigrated` event that has a survivor `to_stable_id`.
  # Anchored to the SURVIVOR's stable_id so the per-cap focus filter on
  # the assessment matrix surfaces the entry beside ratings/evidence/
  # comments that now live under the survivor.
  CAPABILITY_MIGRATED_KIND = "capability_migrated"

  # Orphan-envelope entry — emitted once per `FrameworkVersionMigrated`
  # event when there is at least one archived/split mapping. Framework-
  # scoped (no `capability_stable_id`) because there's no survivor cell
  # to anchor it to.
  CAPABILITIES_ORPHANED_KIND = "capabilities_orphaned"

  # Assessment-authority events (framework-scoped, no capability coords).
  # `reporting_manager_recorded` only fires on an actual manager change, so it
  # is genuine history rather than per-sync noise.
  AUTHORITY_KINDS = {
    PersonDevelopment::Events::ManagerRatingDelegated          => "delegation_granted",
    PersonDevelopment::Events::ManagerRatingDelegationRevoked  => "delegation_revoked",
    PersonDevelopment::Events::ReportingManagerRecorded        => "reporting_manager_recorded"
  }.freeze

  # Authority kinds gated by the same privacy rule as manager ratings (they
  # reveal manager-side process). `reporting_manager_recorded` is NOT gated —
  # the assessee knows their own manager.
  DELEGATION_KINDS = %w[delegation_granted delegation_revoked].freeze

  MANAGER_KINDS = %w[manager_rated manager_rating_revised manager_rating_cleared].freeze

  # Maps each attributable rating entry kind to the payload key carrying its
  # actor's Person id. Drives both name preloading (`actor_names`) and the
  # per-entry `actor_name` merge. Self-ratings are omitted — the actor is
  # always the assessee, so attribution would be redundant.
  ACTOR_ID_KEYS = {
    "manager_rated"          => :rated_by_id,
    "manager_rating_revised" => :rated_by_id,
    "manager_rating_cleared" => :rated_by_id,
    "assessment_aligned"     => :aligned_by_id,
    "alignment_cleared"      => :cleared_by_id,
    "delegation_granted"     => :granted_by_id,
    "delegation_revoked"     => :revoked_by_id
  }.freeze

  # Evidence link/relink events carry their actor's Person id under an
  # event-specific key. Used to preload (`actor_names`) and merge an
  # `actor_name` onto the entry payload so the feed names who linked /
  # unlinked / moved the evidence — nil-safe for historical events.
  EVIDENCE_LINK_ACTOR_KEYS = {
    PersonDevelopment::Events::EvidenceLinkAdded   => :linked_by_id,
    PersonDevelopment::Events::EvidenceLinkRemoved => :removed_by_id,
    PersonDevelopment::Events::EvidenceRelinked    => :relinked_by_id
  }.freeze

  # @param assignment [PersonFrameworkAssignment]
  # @param context [Symbol] :self / :manager / :alignment
  # @param viewer_person_id [String, nil] UUID of the current viewer
  # @param viewer_sees_all [Boolean] true for assessee + manager-chain + admin
  # @param alignment_started [Boolean] whether the current cycle has reached
  #   `aligning` or beyond — gates manager-rating visibility for assessee
  # @param event_store [RailsEventStore::Client] override for tests
  def initialize(assignment:, context: :self, viewer_person_id: nil,
                 viewer_sees_all: false, alignment_started: false,
                 event_store: Rails.configuration.event_store)
    @assignment = assignment
    @context = context&.to_sym
    @viewer_person_id = viewer_person_id
    @viewer_sees_all = viewer_sees_all
    @alignment_started = alignment_started
    @event_store = event_store
  end

  # @return [Array<Entry>] reverse-chronological entries the viewer may see
  def call
    entries = rating_entries + relink_entries + link_entries + evidence_entries +
              alignment_entries + reopen_entries + comment_entries + migration_entries +
              authority_entries
    entries.sort_by { |e| e.occurred_at || Time.at(0) }.reverse
  end

  private

  # Cached lookup of {capability_stable_id => { name:, category_id: }}
  # for the current framework. Used to enrich entries with the
  # capability name (for human-readable summaries) and category_id
  # (so the activity feed can match category-level matrix focus and
  # navigate cross-tab).
  def capability_lookup
    @capability_lookup ||= FrameworkState::Capability
      .joins(:category)
      .merge(FrameworkState::CapabilityCategory.where(framework_id: @assignment.framework_id))
      .pluck(:stable_id, :name, :category_id)
      .to_h { |stable_id, name, category_id| [ stable_id, { name: name, category_id: category_id } ] }
  end

  def capability_name_for(stable_id)
    capability_lookup.dig(stable_id, :name)
  end

  def category_id_for(stable_id)
    capability_lookup.dig(stable_id, :category_id)
  end

  def stream_events
    @stream_events ||= begin
      stream = EventStreamNaming.person_development_stream(
        @assignment.person_id, @assignment.framework_id
      )
      @event_store.read.stream(stream).to_a
    end
  end

  def rating_entries
    stream_events.filter_map do |event|
      kind = RATING_KINDS[event.class]
      next unless kind
      next if hide_manager_rating?(kind)

      data = event.data.with_indifferent_access
      # Resolve the actor's name from the event's actor id (a domain fact
      # captured at write time — e.g. the assessee's *current* manager can
      # differ from who actually rated). Merged into the payload under an
      # `actor_name` key so the view stays a dumb renderer. nil-safe:
      # historical events carry no actor id → name stays nil → the view
      # falls back to a generic label.
      actor_id = data[ACTOR_ID_KEYS[kind]] if ACTOR_ID_KEYS.key?(kind)
      data = data.merge(actor_name: actor_names[actor_id]) if actor_id
      # `via_delegation` is stamped on the event at write time (accurate at
      # event time); historical events lack it → no badge.
      stable_id = data[:capability_stable_id]
      Entry.new(
        id: event.event_id,
        kind: kind,
        occurred_at: event_timestamp(event),
        payload: data,
        capability_stable_id: stable_id,
        level_ordinal: data[:level_ordinal],
        cycle_id: data[:cycle_id],
        capability_name: capability_name_for(stable_id),
        category_id: category_id_for(stable_id)
      )
    end
  end

  # {Person id => name} for every actor referenced by an attributed rating
  # entry on this stream (rating manager, aligner, alignment-clearer). Loaded
  # in one query and memoised so the per-entry merge above never N+1s. Person
  # is acts_as_tenant-scoped, and the actor is always in the assessee's tenant,
  # so the active tenant scope resolves them.
  def actor_names
    @actor_names ||= begin
      ids = stream_events.flat_map do |event|
        if (kind = RATING_KINDS[event.class] || AUTHORITY_KINDS[event.class])
          keys = [ ACTOR_ID_KEYS[kind], :delegate_person_id, :manager_id ].compact
          keys.map { |key| event.data[key] || event.data[key.to_s] }
        elsif (key = EVIDENCE_LINK_ACTOR_KEYS[event.class])
          [ event.data[key] || event.data[key.to_s] ]
        else
          []
        end
      end.compact.uniq
      ids.empty? ? {} : Person.where(id: ids).pluck(:id, :name).to_h
    end
  end

  # Reads EvidenceRelinked events and emits one feed entry each. The
  # entry's `capability_stable_id` / `level_ordinal` / `category_id`
  # point at the NEW location (so click-navigate goes there), while the
  # PREVIOUS coords are stuffed into payload alongside the
  # human-readable previous capability name for the summary line. Peers
  # without sees_all are filtered to relinks they themselves performed,
  # mirroring the same author gate as evidence_entries.
  def relink_entries
    stream_events.filter_map do |event|
      next unless event.is_a?(PersonDevelopment::Events::EvidenceRelinked)

      data = event.data.with_indifferent_access
      next if !@viewer_sees_all && data[:relinked_by_id] != @viewer_person_id

      new_stable_id = data[:new_capability_stable_id]
      Entry.new(
        id: event.event_id,
        kind: RELINK_KIND,
        occurred_at: event_timestamp(event),
        payload: data.merge(
          previous_capability_name: capability_name_for(data[:previous_capability_stable_id]),
          new_capability_name: capability_name_for(new_stable_id),
          actor_name: actor_names[data[:relinked_by_id]]
        ),
        capability_stable_id: new_stable_id,
        level_ordinal: data[:new_level_ordinal],
        cycle_id: nil,
        capability_name: capability_name_for(new_stable_id),
        category_id: category_id_for(new_stable_id)
      )
    end
  end

  # Reads EvidenceLinkAdded / EvidenceLinkRemoved events and emits one feed
  # entry each, anchored to the affected (capability, level) cell so the
  # per-cell focus filter surfaces them. Peers without sees_all are filtered
  # to link changes they themselves performed, mirroring the author gate on
  # evidence_entries. The evidence's title (when present) is folded into the
  # payload for the summary line.
  def link_entries
    return [] if !@viewer_sees_all && @viewer_person_id.nil?

    stream_events.filter_map do |event|
      case event
      when PersonDevelopment::Events::EvidenceLinkAdded
        build_link_entry(event, kind: LINK_ADDED_KIND, actor_key: :linked_by_id)
      when PersonDevelopment::Events::EvidenceLinkRemoved
        build_link_entry(event, kind: LINK_REMOVED_KIND, actor_key: :removed_by_id)
      end
    end
  end

  def build_link_entry(event, kind:, actor_key:)
    data = event.data.with_indifferent_access
    return nil if !@viewer_sees_all && data[actor_key] != @viewer_person_id

    stable_id = data[:capability_stable_id]
    Entry.new(
      id: event.event_id,
      kind: kind,
      occurred_at: event_timestamp(event),
      payload: data.merge(
        evidence_title: evidence_title_for(data[:evidence_id]),
        actor_name: actor_names[data[actor_key]]
      ),
      capability_stable_id: stable_id,
      level_ordinal: data[:level_ordinal],
      cycle_id: nil,
      capability_name: capability_name_for(stable_id),
      category_id: category_id_for(stable_id)
    )
  end

  # Best-effort title for the evidence behind a link entry (nil when the
  # item has no title or has since been hard-deleted). Memoised per request.
  def evidence_title_for(evidence_id)
    (@evidence_titles ||= {})[evidence_id] ||=
      EvidenceItem.where(id: evidence_id).pick(:title)
  end

  def evidence_entries
    # When the viewer is a peer (sees_all=false) and the viewer's
    # person is unknown, filtering by author_id would degrade to
    # `WHERE author_id IS NULL` — which surfaces only orphaned items
    # rather than nothing. Bail early instead.
    return [] if !@viewer_sees_all && @viewer_person_id.nil?

    scope = EvidenceItem
      .for_person(@assignment.person_id)
      .for_framework(@assignment.framework_id)
      .includes(:author, :withdrawn_by)
    scope = scope.where(author_id: @viewer_person_id) unless @viewer_sees_all

    scope.flat_map do |item|
      stable_id = item.capability_stable_id
      base_attrs = {
        capability_stable_id: stable_id,
        level_ordinal: item.level_ordinal,
        capability_name: capability_name_for(stable_id),
        category_id: category_id_for(stable_id)
      }
      entries = [
        Entry.new(
          id: "evidence_recorded:#{item.id}",
          kind: "evidence_recorded",
          occurred_at: item.recorded_at,
          payload: item,
          **base_attrs
        )
      ]
      if item.withdrawn? && item.withdrawn_at
        entries << Entry.new(
          id: "evidence_withdrawn:#{item.id}",
          kind: "evidence_withdrawn",
          occurred_at: item.withdrawn_at,
          payload: item,
          **base_attrs
        )
      end
      entries
    end
  end

  # Reads the {PersonDevelopmentComment} read model and emits one feed
  # entry per active comment. Threaded alongside ratings/evidence so the
  # conversation context surrounding any cell is visible inline.
  #
  # Deleted comments are intentionally omitted from the activity feed —
  # tombstones still render inside the focused cell's thread (so reply
  # chains stay coherent), but the feed shouldn't surface noise from
  # removed posts. Edited comments are NOT given a separate "edited"
  # entry — the card itself shows an `(edited)` marker, and a feed
  # entry per edit would be excessive for an informal conversation lane.
  def comment_entries
    PersonDevelopmentComment
      .active
      .for_person(@assignment.person_id)
      .for_framework(@assignment.framework_id)
      .where(commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL)
      .includes(:author, parent: :author)
      .map do |comment|
        stable_id = comment.capability_stable_id
        Entry.new(
          id: "comment_posted:#{comment.id}",
          kind: "comment_posted",
          occurred_at: comment.posted_at,
          payload: comment,
          capability_stable_id: stable_id,
          level_ordinal: comment.level_ordinal,
          cycle_id: nil,
          capability_name: capability_name_for(stable_id),
          category_id: category_id_for(stable_id)
        )
      end
  end

  def alignment_entries
    AssessmentCycleProgress
      .joins("INNER JOIN assessment_cycles ac ON ac.cycle_id = " \
             "assessment_cycle_progress.cycle_id")
      .where(person_id: @assignment.person_id)
      .where("ac.framework_id = ?", @assignment.framework_id)
      .flat_map do |progress|
        out = []
        if progress.alignment_started_at
          out << Entry.new(
            id: "alignment_started:#{progress.id}",
            kind: "alignment_started",
            occurred_at: progress.alignment_started_at,
            payload: { cycle_id: progress.cycle_id,
                       started_by_id: progress.alignment_started_by_id }.with_indifferent_access,
            cycle_id: progress.cycle_id
          )
        end
        if progress.aligned_at
          out << Entry.new(
            id: "alignment_completed:#{progress.id}",
            kind: "alignment_completed",
            occurred_at: progress.aligned_at,
            payload: { cycle_id: progress.cycle_id,
                       completed_by_id: progress.aligned_by_id }.with_indifferent_access,
            cycle_id: progress.cycle_id
          )
        end
        out
      end
  end

  # One entry per `AlignmentReopened` event on this person's stream.
  # Sourced from the stream (not the progress row) because a re-open
  # clears the completion timestamps the progress-derived alignment
  # entries read — only the immutable event records that it happened.
  # An alignment milestone, so visible to both parties like
  # started/completed.
  def reopen_entries
    stream_events.filter_map do |event|
      next unless event.is_a?(PersonDevelopment::Events::AlignmentReopened)

      data = event.data.with_indifferent_access
      Entry.new(
        id: "alignment_reopened:#{event.event_id}",
        kind: "alignment_reopened",
        occurred_at: event_timestamp(event),
        payload: { cycle_id: data[:cycle_id],
                   reopened_by_id: data[:reopened_by_id] }.with_indifferent_access,
        cycle_id: data[:cycle_id]
      )
    end
  end

  # Expands every `FrameworkVersionMigrated` event on this person's
  # stream into per-capability entries (anchored to each survivor) plus
  # at most one orphan envelope per event listing the archived/split
  # capabilities that have no survivor. Counts are baked into the event
  # payload at emit time so no extra joins are needed here.
  def migration_entries
    stream_events.flat_map do |event|
      next [] unless event.is_a?(PersonDevelopment::Events::FrameworkVersionMigrated)

      data = event.data.with_indifferent_access
      occurred_at = event_timestamp(event)
      mappings = Array(data[:mappings])

      per_cap = mappings.filter_map do |mapping|
        m = mapping.with_indifferent_access
        next if m[:to_stable_id].nil?
        next unless %w[same evolved].include?(m[:mapping_type])

        to_stable_id = m[:to_stable_id]
        Entry.new(
          id: "capability_migrated:#{event.event_id}:#{m[:from_stable_id]}",
          kind: CAPABILITY_MIGRATED_KIND,
          occurred_at: occurred_at,
          payload: m.merge(old_version: data[:old_version], new_version: data[:new_version]),
          capability_stable_id: to_stable_id,
          level_ordinal: nil,
          cycle_id: nil,
          capability_name: capability_name_for(to_stable_id),
          category_id: category_id_for(to_stable_id)
        )
      end

      orphaned = mappings.select do |m|
        kind = m.with_indifferent_access[:mapping_type]
        %w[archived split].include?(kind)
      end

      envelope = if orphaned.any?
        [
          Entry.new(
            id: "capabilities_orphaned:#{event.event_id}",
            kind: CAPABILITIES_ORPHANED_KIND,
            occurred_at: occurred_at,
            payload: { old_version: data[:old_version],
                       new_version: data[:new_version],
                       orphaned: orphaned }.with_indifferent_access,
            capability_stable_id: nil,
            level_ordinal: nil,
            cycle_id: nil,
            capability_name: nil,
            category_id: nil
          )
        ]
      else
        []
      end

      per_cap + envelope
    end
  end

  # Reads the three assessment-authority events from the stream and emits one
  # framework-scoped entry each. Names for the actor, the delegate, and (for
  # reporting-manager changes) the new manager are merged into the payload.
  def authority_entries
    stream_events.filter_map do |event|
      kind = AUTHORITY_KINDS[event.class]
      next unless kind
      next if hide_authority_entry?(kind)

      data = event.data.with_indifferent_access
      actor_id = data[ACTOR_ID_KEYS[kind]] if ACTOR_ID_KEYS.key?(kind)
      data = data.merge(actor_name: actor_names[actor_id]) if actor_id
      data = data.merge(delegate_name: actor_names[data[:delegate_person_id]]) if data[:delegate_person_id]
      data = data.merge(manager_name: actor_names[data[:manager_id]]) if data[:manager_id]

      Entry.new(
        id: event.event_id,
        kind: kind,
        occurred_at: event_timestamp(event),
        payload: data,
        capability_stable_id: nil,
        level_ordinal: nil,
        cycle_id: nil,
        capability_name: nil,
        category_id: nil
      )
    end
  end

  def hide_authority_entry?(kind)
    return false unless DELEGATION_KINDS.include?(kind)

    # Delegation grant/revoke follow the manager-rating privacy gate.
    return true unless @viewer_sees_all
    return true if @context == :self && !@alignment_started

    false
  end

  def hide_manager_rating?(kind)
    return false unless MANAGER_KINDS.include?(kind)
    # Peers can never see manager-source ratings.
    return true unless @viewer_sees_all
    # Assessee in :self context: only after alignment has started.
    return true if @context == :self && !@alignment_started

    false
  end

  def event_timestamp(event)
    event.metadata[:timestamp] || (event.respond_to?(:timestamp) ? event.timestamp : nil)
  end
end
