# frozen_string_literal: true

# Top-level value node of the {Frameworks::ExplorerGraph}.
#
# Duck-types the surface of {FrameworkState::Framework} that
# {Frameworks::MatrixDataBuilder} reads, so the controller can swap AR
# records for this snapshot without further changes.
#
# {#suggested_edits} delegates to the `FrameworkState::SuggestedEdit` AR
# relation so {Frameworks::FocusedSuggestionsQuery} keeps working unchanged —
# suggestions are a separate, version-agnostic concern.
#
Frameworks::ExplorerGraph::Framework = Data.define(
  :framework_id,
  :name,
  :current_published_version,
  :draft_in_progress,
  :draft_version,
  :role_families,
  :capability_categories
) do
  # @return [ActiveRecord::Relation<FrameworkState::SuggestedEdit>]
  def suggested_edits
    FrameworkState::SuggestedEdit.where(framework_id: framework_id)
  end
end
