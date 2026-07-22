# frozen_string_literal: true

# Assembles one evidence linkage's discussion thread: the comments
# anchored to the (evidence_id, capability_stable_id, level_ordinal)
# natural key, plus the linkage's lifecycle story read from the person
# development stream — linked, valence reclassified, link removed,
# item withdrawn. The view interleaves both chronologically so the
# thread reads as the linkage's history, with the reclassification
# landing inside the conversation that caused it.
#
# Lifecycle entries come from the stream (not read models) because the
# EvidenceLink row only holds the latest state — the history of a
# linkage that was revalenced twice or removed and re-added exists only
# as events. Same approach as {Assessments::ActivityFeedQuery}. The
# cost is confined to the lazily-loaded thread frame; nothing on the
# matrix render path reads the stream.
#
class Assessments::EvidenceLinkThreadQuery
  LIFECYCLE_EVENTS = [
    PersonDevelopment::Events::EvidenceRecorded,
    PersonDevelopment::Events::EvidenceLinkAdded,
    PersonDevelopment::Events::EvidenceLinkRemoved,
    PersonDevelopment::Events::EvidenceLinkRevalenced,
    PersonDevelopment::Events::EvidenceRelinked,
    PersonDevelopment::Events::EvidenceWithdrawn
  ].freeze

  # One lifecycle row. `kind` is :linked | :revalenced | :removed |
  # :withdrawn; `valence`/`previous_valence`/`reason` are kind-specific
  # and nil otherwise. `actor_name` is resolved from the Person read
  # model and nil when the person no longer resolves.
  Entry = Data.define(:kind, :actor_name, :valence, :previous_valence, :reason, :at)

  # @param item [EvidenceItem]
  # @param capability_stable_id [String]
  # @param level_ordinal [Integer]
  # @param event_store [RailsEventStore::Client] override for tests
  def initialize(item:, capability_stable_id:, level_ordinal:,
                 event_store: Rails.configuration.event_store)
    @item = item
    @capability_stable_id = capability_stable_id
    @level_ordinal = level_ordinal
    @event_store = event_store
  end

  # All comments on the linkage, deleted ones included (the thread view
  # renders load-bearing tombstones), chronological.
  #
  # @return [Array<PersonDevelopmentComment>]
  def comments
    @comments ||= PersonDevelopmentComment
      .on_evidence_link(@item.id, @capability_stable_id, @level_ordinal)
      .for_person(@item.person_id)
      .for_framework(@item.framework_id)
      .includes(:author)
      .chronological
      .to_a
  end

  # The linkage's current link row — nil when it was never projected,
  # `removed?` when the link has been taken off. Drives the thread's
  # state notice and current-valence badge.
  #
  # @return [EvidenceLink, nil]
  def link
    return @link if defined?(@link)

    @link = EvidenceLink
      .for_cell(@capability_stable_id, @level_ordinal)
      .find_by(evidence_id: @item.id)
  end

  # @return [Array<Entry>] lifecycle rows for this linkage, chronological
  def lifecycle_entries
    @lifecycle_entries ||= begin
      entries = stream_events.filter_map { |event| build_entry(event) }
      resolve_actor_names(entries)
    end
  end

  private

  def stream_events
    stream = EventStreamNaming.person_development_stream(
      @item.person_id, @item.framework_id, tenant: ActsAsTenant.current_tenant
    )
    @event_store.read.stream(stream).of_type(LIFECYCLE_EVENTS).to_a
  end

  # Returns [kind, actor_id, extras] for events that concern this
  # linkage; nil for everything else. Raw actor ids are swapped for
  # names in one batched lookup afterwards.
  def build_entry(event)
    data = event.data
    return nil unless data[:evidence_id] == @item.id

    at = event.metadata[:timestamp]
    case event
    when PersonDevelopment::Events::EvidenceRecorded
      return nil unless on_cell?(data[:capability_stable_id], data[:level_ordinal])

      [ Entry.new(kind: :linked, actor_name: nil, valence: data[:valence],
                  previous_valence: nil, reason: nil, at: at), data[:author_id] ]
    when PersonDevelopment::Events::EvidenceLinkAdded
      return nil unless on_cell?(data[:capability_stable_id], data[:level_ordinal])

      [ Entry.new(kind: :linked, actor_name: nil, valence: data[:valence],
                  previous_valence: nil, reason: nil, at: at), data[:linked_by_id] ]
    when PersonDevelopment::Events::EvidenceLinkRemoved
      return nil unless on_cell?(data[:capability_stable_id], data[:level_ordinal])

      [ Entry.new(kind: :removed, actor_name: nil, valence: nil,
                  previous_valence: nil, reason: data[:reason], at: at), data[:removed_by_id] ]
    when PersonDevelopment::Events::EvidenceLinkRevalenced
      return nil unless on_cell?(data[:capability_stable_id], data[:level_ordinal])

      [ Entry.new(kind: :revalenced, actor_name: nil, valence: data[:valence],
                  previous_valence: data[:previous_valence], reason: nil, at: at), data[:changed_by_id] ]
    when PersonDevelopment::Events::EvidenceRelinked
      # Historical event (no longer emitted): a relink is remove + add.
      if on_cell?(data[:previous_capability_stable_id], data[:previous_level_ordinal])
        [ Entry.new(kind: :removed, actor_name: nil, valence: nil,
                    previous_valence: nil, reason: nil, at: at), data[:relinked_by_id] ]
      elsif on_cell?(data[:new_capability_stable_id], data[:new_level_ordinal])
        [ Entry.new(kind: :linked, actor_name: nil, valence: nil,
                    previous_valence: nil, reason: nil, at: at), data[:relinked_by_id] ]
      end
    when PersonDevelopment::Events::EvidenceWithdrawn
      # Item-level: ends every linkage's discussion, so it belongs in
      # each thread regardless of cell.
      [ Entry.new(kind: :withdrawn, actor_name: nil, valence: nil,
                  previous_valence: nil, reason: data[:reason], at: at), data[:withdrawn_by_id] ]
    end
  end

  def on_cell?(capability_stable_id, level_ordinal)
    capability_stable_id == @capability_stable_id && level_ordinal == @level_ordinal
  end

  def resolve_actor_names(pairs)
    names = Person.where(id: pairs.map(&:last).compact.uniq).pluck(:id, :name).to_h
    pairs.map do |entry, actor_id|
      entry.with(actor_name: names[actor_id])
    end
  end
end
