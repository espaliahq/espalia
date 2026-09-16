# frozen_string_literal: true

# The perspectives a viewer sees *beside* the one they are working in —
# "Mgr" and "Agreed" while self-assessing, "Self" and "Agreed" in the
# manager view, both parties during alignment.
#
# One definition, because four surfaces build this list (the section
# header and the three rating controllers' Turbo Stream responses) and a
# fifth reads it. Each entry carries its own **context**, not just a
# label, so a reader can apply the coverage rule to that perspective's
# own ratings: "Self: 0%" beside a manager's 100% usually means the
# assessee has not rated yet, which is not a score.
class Assessments::SecondaryPerspectives
  # viewer's context => [[label, the matrix_data key, that perspective's own context]]
  ENTRIES = {
    self: [ [ "Mgr", :manager_scoring, :manager ], [ "Agreed", :aligned_scoring, :alignment ] ],
    manager: [ [ "Self", :self_scoring, :self ], [ "Agreed", :aligned_scoring, :alignment ] ],
    alignment: [ [ "Self", :self_scoring, :self ], [ "Mgr", :manager_scoring, :manager ] ]
  }.freeze

  # @param matrix_data [Hash]
  # @param context [Symbol] the viewer's own context
  # @return [Array<Hash>] `{ label:, context:, scoring: }`, dropping any
  #   perspective with no scoring at all
  def self.for(matrix_data, context)
    ENTRIES.fetch(context, []).filter_map do |label, key, own_context|
      scoring = matrix_data[key]
      next unless scoring

      { label: label, context: own_context, scoring: scoring }
    end
  end

  # The same list narrowed to one category's score.
  #
  # @return [Array<Hash>] `{ label:, context:, score: }`
  def self.category_scores(matrix_data, context, category_id)
    self.for(matrix_data, context).filter_map do |entry|
      score = entry[:scoring].dig(:category_scores, category_id)
      next unless score

      { label: entry[:label], context: entry[:context], score: score }
    end
  end
end
