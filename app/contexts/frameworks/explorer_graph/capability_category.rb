# frozen_string_literal: true

# Capability-category node. Categories apply live on
# `CapabilityCategoryAdded` and can be archived via
# `CapabilityCategoryArchived` once they hold no active capabilities.
# Archive is shape-changing — the snapshot reflects the archive only
# after publish (the aggregate's in-memory `status` flips on the event,
# but the explorer respects the published view by exposing it through
# `status` rather than a `pending_archive` flag, since an empty
# category's archival doesn't alter any visible cells).
#
Frameworks::ExplorerGraph::CapabilityCategory = Data.define(
  :category_id,
  :name,
  :description,
  :ordinal,
  :deficit_threshold,
  :overperformance_cap,
  :status,
  :capabilities
) do
  def to_hash_tree
    {
      "category_id" => category_id,
      "name" => name,
      "description" => description,
      "ordinal" => ordinal,
      "deficit_threshold" => deficit_threshold,
      "overperformance_cap" => overperformance_cap,
      "status" => status,
      "capabilities" => capabilities.map(&:to_hash_tree)
    }
  end

  def self.from_hash_tree(h)
    new(
      category_id: h["category_id"],
      name: h["name"],
      description: h["description"],
      ordinal: h["ordinal"],
      deficit_threshold: h["deficit_threshold"],
      overperformance_cap: h["overperformance_cap"],
      status: h.fetch("status", "active"),
      capabilities: h.fetch("capabilities", []).map { |x| Frameworks::ExplorerGraph::Capability.from_hash_tree(x) }
    )
  end
end
