# frozen_string_literal: true

# Who may read a dismissed placement suggestion and its reason: anyone who
# sees the whole assessment, and whoever dismissed it. Any other peer sees
# neither. The activity feed and the link thread both ask here, so a wider
# rule is one change.
module Assessments::SuggestionDismissalVisibility
  # @param dismissed_by_id [String, nil] from the dismissal event
  # @param viewer_person_id [String, nil]
  # @param viewer_sees_all [Boolean] assessee, manager chain, delegate or admin
  # @return [Boolean]
  def self.visible?(dismissed_by_id:, viewer_person_id:, viewer_sees_all:)
    return true if viewer_sees_all

    viewer_person_id.present? && dismissed_by_id == viewer_person_id
  end
end
