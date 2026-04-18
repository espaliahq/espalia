# frozen_string_literal: true

# Capability-category node. Shape-preserving — categories apply live on
# `CapabilityCategoryAdded`, and there is no archive command, so neither
# draft-state flag is needed.
#
Frameworks::ExplorerGraph::CapabilityCategory = Data.define(
  :category_id,
  :name,
  :description,
  :ordinal,
  :deficit_threshold,
  :overperformance_cap,
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
      capabilities: h.fetch("capabilities", []).map { |x| Frameworks::ExplorerGraph::Capability.from_hash_tree(x) }
    )
  end
end
