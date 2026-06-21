# frozen_string_literal: true

# The `#request-candidates` turbo-frame body: typeahead search results, replaced
# on each debounced keystroke (the frame `src` carries the query). Renders rows
# of `RequestCandidate`, an empty state, or a prompt before any query.
class Views::Evidence::RequestCandidatesFrame < Views::Base
  # @param candidates [Array<Assessments::RequestCandidates::Candidate>]
  # @param query [String, nil] the current search term
  def initialize(candidates:, query:)
    @candidates = candidates
    @query = query
  end

  def view_template
    turbo_frame_tag("request-candidates") do
      if @query.blank?
        empty("Start typing a name or email to search.")
      elsif @candidates.empty?
        empty("No matches for “#{@query}”.")
      else
        div(class: "divide-y divide-gray-100 dark:divide-gray-800") do
          @candidates.each { |candidate| render Views::Evidence::RequestCandidate.new(candidate:) }
        end
      end
    end
  end

  private

  def empty(text)
    p(class: "px-3 py-3 text-xs text-gray-500 dark:text-gray-400") { text }
  end
end
