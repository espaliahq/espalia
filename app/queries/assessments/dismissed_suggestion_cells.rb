# frozen_string_literal: true

# Which cell each dismissed suggestion is about today. The dismissal event
# names no cell, and the suggestion's row can't answer for every one: a
# framework migration that lands two dismissals on one cell keeps only one
# row. So the cell is read from the stream: where the suggestion was made,
# carried through each same or evolved mapping since, as the rows are.
module Assessments::DismissedSuggestionCells
  MIGRATING = %w[same evolved].freeze

  # @param events [Enumerable<RubyEventStore::Event>] the development stream, oldest first
  # @return [Hash{String => Array(String, Integer)}] suggestion id to [capability_stable_id, level_ordinal]
  def self.from(events)
    cells = {}
    dismissed = Set.new
    events.each do |event|
      data = event.data
      case event
      when PersonDevelopment::Events::EvidencePlacementSuggested
        cells[data[:suggestion_id]] = [ data[:capability_stable_id], data[:level_ordinal] ] unless dismissed.include?(data[:suggestion_id])
      when PersonDevelopment::Events::EvidencePlacementSuggestionDismissed
        dismissed << data[:suggestion_id]
      when PersonDevelopment::Events::FrameworkVersionMigrated
        carry(cells, data[:mappings])
      end
    end
    cells.slice(*dismissed)
  end

  # One mapping at a time, as the projection moves the rows.
  def self.carry(cells, mappings)
    Array(mappings).each do |mapping|
      from, to = mapping.values_at(:from_stable_id, :to_stable_id)
      next unless MIGRATING.include?(mapping[:mapping_type])
      next if to.nil? || to == from

      cells.transform_values! { |stable_id, level| [ stable_id == from ? to : stable_id, level ] }
    end
  end
  private_class_method :carry
end
