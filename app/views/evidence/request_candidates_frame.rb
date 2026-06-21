# frozen_string_literal: true

# The `#request-candidates` turbo-frame body: typeahead search results, replaced
# on each debounced keystroke (the frame `src` carries the query). Rendered
# inside an absolutely-positioned wrapper in RequestForm so it **floats as a
# dropdown** over the content below instead of resizing the modal — so the frame
# renders a bordered panel only when there's a query (results or "no matches"),
# and nothing at all before the user types.
class Views::Evidence::RequestCandidatesFrame < Views::Base
  PANEL = "rounded-md border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 " \
          "shadow-lg max-h-64 overflow-y-auto"

  # @param candidates [Array<Assessments::RequestCandidates::Candidate>]
  # @param query [String, nil] the current search term
  def initialize(candidates:, query:)
    @candidates = candidates
    @query = query
  end

  def view_template
    turbo_frame_tag("request-candidates") do
      panel unless @query.blank?
    end
  end

  private

  def panel
    div(class: PANEL) do
      if @candidates.empty?
        empty("No matches for “#{@query}”.")
      else
        div(class: "divide-y divide-gray-100 dark:divide-gray-800") do
          @candidates.each { |candidate| render Views::Evidence::RequestCandidate.new(candidate:) }
        end
      end
    end
  end

  def empty(text)
    p(class: "px-3 py-3 text-xs text-gray-500 dark:text-gray-400") { text }
  end
end
