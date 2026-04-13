# frozen_string_literal: true

# Reusable CSS class logic for pending suggestion visual affordances.
#
# Include in any Phlex view component that renders framework entity text
# to apply consistent decoration when pending suggestions exist.
#
# Visual language:
# - Pending edit: amber wavy underline on existing text
# - Pending create: amber wavy underline on proposed text (ghost entry)
# - Pending delete: red strikethrough on existing text
#
module Views::Frameworks::Explorer::Concerns::SuggestionDecoration
  PENDING_EDIT_CLASSES = "underline decoration-amber-400 decoration-wavy decoration-2 underline-offset-4"
  PENDING_DELETE_CLASSES = "line-through decoration-red-400 decoration-2"

  # Returns Tailwind CSS classes for text that has pending suggestions.
  #
  # @param pending_edit_count [Integer] number of pending edit/create suggestions
  # @param pending_delete_count [Integer] number of pending delete suggestions
  # @return [String] space-separated CSS classes, or empty string
  def suggestion_text_classes(pending_edit_count: 0, pending_delete_count: 0)
    return PENDING_DELETE_CLASSES if pending_delete_count > 0
    return PENDING_EDIT_CLASSES if pending_edit_count > 0

    ""
  end
end
