# frozen_string_literal: true

# The person picker's typeahead results frame, replaced on each debounced
# keystroke (the frame `src` carries the query). Renders a floating panel
# only when there's a query, mirroring the evidence-request candidates
# frame it was generalised from.
class Views::Shared::PersonPickerCandidatesFrame < Views::Base
  PANEL = "rounded-md border border-default bg-overlay " \
          "shadow-overlay max-h-64 overflow-y-auto"

  # @param frame_id [String]
  # @param entries [Array<Hash>] { person:, subtitle: nil }
  # @param query [String, nil]
  def initialize(frame_id:, entries:, query:)
    @frame_id = frame_id
    @entries = entries
    @query = query
  end

  def view_template
    turbo_frame_tag(@frame_id) do
      panel unless @query.blank?
    end
  end

  private

  def panel
    div(class: PANEL) do
      if @entries.empty?
        p(class: "px-3 py-3 text-xs text-muted") { "No matches for “#{@query}”." }
      else
        div(class: "divide-y divide-subtle") do
          @entries.each do |entry|
            render Views::Shared::PersonPickerCandidate.new(person: entry[:person], subtitle: entry[:subtitle])
          end
        end
      end
    end
  end
end
