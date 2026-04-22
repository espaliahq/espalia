# frozen_string_literal: true

# Capability node of the {Frameworks::ExplorerGraph}.
#
# `status` always reflects the framework's *published* view of the
# capability: a capability archived in an open draft keeps `status: "active"`
# here and sets `pending_archive: true` instead. The builder computes this —
# the aggregate's `@capabilities[cid][:status]` flips to `:archived` the
# moment the archive event applies, even while a draft is in progress, but
# the published view only reflects that flip on publish (see ADR-16).
#
# `added_in_draft: true` means the capability was added via `CapabilityAdded`
# inside the current open draft and must be hidden from view-mode rendering.
#
Frameworks::ExplorerGraph::Capability = Data.define(
  :capability_id,
  :stable_id,
  :category_id,
  :name,
  :description,
  :status,
  :bindings,
  :expectations,
  :added_in_draft,
  :pending_archive
) do
  def to_hash_tree
    {
      "capability_id" => capability_id,
      "stable_id" => stable_id,
      "category_id" => category_id,
      "name" => name,
      "description" => description,
      "status" => status,
      "bindings" => bindings.map(&:to_hash_tree),
      "expectations" => expectations.map(&:to_hash_tree),
      "added_in_draft" => added_in_draft,
      "pending_archive" => pending_archive
    }
  end

  def self.from_hash_tree(h)
    new(
      capability_id: h["capability_id"],
      stable_id: h["stable_id"],
      category_id: h["category_id"],
      name: h["name"],
      description: h["description"],
      status: h["status"],
      bindings: h.fetch("bindings", []).map { |x| Frameworks::ExplorerGraph::CapabilityRoleBinding.from_hash_tree(x) },
      expectations: h.fetch("expectations", []).map { |x| Frameworks::ExplorerGraph::BehaviouralExpectation.from_hash_tree(x) },
      added_in_draft: h["added_in_draft"],
      pending_archive: h["pending_archive"]
    )
  end
end
