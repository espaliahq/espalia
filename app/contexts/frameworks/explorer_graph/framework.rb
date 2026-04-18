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
# JSON-serializable via {#to_hash_tree} / {.from_hash_tree}. Keys are strings
# to match Postgres's jsonb round-trip.
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

  def to_hash_tree
    {
      "framework_id" => framework_id,
      "name" => name,
      "current_published_version" => current_published_version,
      "draft_in_progress" => draft_in_progress,
      "draft_version" => draft_version,
      "role_families" => role_families.map(&:to_hash_tree),
      "capability_categories" => capability_categories.map(&:to_hash_tree)
    }
  end

  def self.from_hash_tree(h)
    new(
      framework_id: h["framework_id"],
      name: h["name"],
      current_published_version: h["current_published_version"],
      draft_in_progress: h["draft_in_progress"],
      draft_version: h["draft_version"],
      role_families: h.fetch("role_families", []).map { |x| Frameworks::ExplorerGraph::RoleFamily.from_hash_tree(x) },
      capability_categories: h.fetch("capability_categories", []).map { |x| Frameworks::ExplorerGraph::CapabilityCategory.from_hash_tree(x) }
    )
  end
end
