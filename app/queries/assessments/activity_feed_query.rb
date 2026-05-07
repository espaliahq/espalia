# frozen_string_literal: true

# Loads the activity feed for an assessment — a unified, reverse-chronological
# stream of typed entries that the right-hand sidebar renders.
#
# Sources:
# - PersonDevelopment events read from the per-(person, framework) RES
#   stream. Captures every rating change (self / manager / aligned) with
#   the timestamp the event was emitted.
# - {EvidenceItem} rows for evidence-recorded and evidence-withdrawn
#   entries (relinks are folded into the recorded entry — the activity
#   feed shows where the evidence currently lives).
# - {AssessmentCycleParticipant} rows for alignment milestones
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
                     :level_ordinal, :cycle_id, keyword_init: true)

  RATING_KINDS = {
    PersonDevelopment::Events::SelfRated              => "self_rated",
    PersonDevelopment::Events::SelfRatingRevised      => "self_rating_revised",
    PersonDevelopment::Events::SelfRatingCleared      => "self_rating_cleared",
    PersonDevelopment::Events::ManagerRated           => "manager_rated",
    PersonDevelopment::Events::ManagerRatingRevised   => "manager_rating_revised",
    PersonDevelopment::Events::ManagerRatingCleared   => "manager_rating_cleared",
    PersonDevelopment::Events::AssessmentAligned      => "assessment_aligned"
  }.freeze

  MANAGER_KINDS = %w[manager_rated manager_rating_revised manager_rating_cleared].freeze

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
    entries = rating_entries + evidence_entries + alignment_entries
    entries.sort_by { |e| e.occurred_at || Time.at(0) }.reverse
  end

  private

  def rating_entries
    stream = EventStreamNaming.person_development_stream(
      @assignment.person_id, @assignment.framework_id
    )
    @event_store.read.stream(stream).to_a.filter_map do |event|
      kind = RATING_KINDS[event.class]
      next unless kind
      next if hide_manager_rating?(kind)

      data = event.data.with_indifferent_access
      Entry.new(
        id: event.event_id,
        kind: kind,
        occurred_at: event_timestamp(event),
        payload: data,
        capability_stable_id: data[:capability_stable_id],
        level_ordinal: data[:level_ordinal],
        cycle_id: data[:cycle_id]
      )
    end
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
    scope = scope.where(author_id: @viewer_person_id) unless @viewer_sees_all

    scope.flat_map do |item|
      entries = [
        Entry.new(
          id: "evidence_recorded:#{item.id}",
          kind: "evidence_recorded",
          occurred_at: item.recorded_at,
          payload: item,
          capability_stable_id: item.capability_stable_id,
          level_ordinal: item.level_ordinal
        )
      ]
      if item.withdrawn? && item.withdrawn_at
        entries << Entry.new(
          id: "evidence_withdrawn:#{item.id}",
          kind: "evidence_withdrawn",
          occurred_at: item.withdrawn_at,
          payload: item,
          capability_stable_id: item.capability_stable_id,
          level_ordinal: item.level_ordinal
        )
      end
      entries
    end
  end

  def alignment_entries
    AssessmentCycleParticipant
      .joins("INNER JOIN assessment_cycles ac ON ac.cycle_id = " \
             "assessment_cycle_participants.cycle_id")
      .where(person_id: @assignment.person_id)
      .where("ac.framework_id = ?", @assignment.framework_id)
      .flat_map do |participant|
        out = []
        if participant.alignment_started_at
          out << Entry.new(
            id: "alignment_started:#{participant.id}",
            kind: "alignment_started",
            occurred_at: participant.alignment_started_at,
            payload: { cycle_id: participant.cycle_id,
                       started_by_id: participant.alignment_started_by_id }.with_indifferent_access,
            cycle_id: participant.cycle_id
          )
        end
        if participant.aligned_at
          out << Entry.new(
            id: "alignment_completed:#{participant.id}",
            kind: "alignment_completed",
            occurred_at: participant.aligned_at,
            payload: { cycle_id: participant.cycle_id,
                       completed_by_id: participant.aligned_by_id }.with_indifferent_access,
            cycle_id: participant.cycle_id
          )
        end
        out
      end
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
