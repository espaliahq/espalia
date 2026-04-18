# frozen_string_literal: true

# Capability-role binding node. `added_in_draft` means this binding was
# created inside an open draft via `CapabilityRoleBindingCreated` and is not
# yet published — view-mode rendering must hide it.
#
Frameworks::ExplorerGraph::CapabilityRoleBinding = Data.define(
  :binding_id,
  :capability_id,
  :role_id,
  :weight,
  :individual_tolerance,
  :added_in_draft
) do
  def to_hash_tree
    {
      "binding_id" => binding_id,
      "capability_id" => capability_id,
      "role_id" => role_id,
      "weight" => weight,
      "individual_tolerance" => individual_tolerance,
      "added_in_draft" => added_in_draft
    }
  end

  def self.from_hash_tree(h)
    new(
      binding_id: h["binding_id"],
      capability_id: h["capability_id"],
      role_id: h["role_id"],
      weight: h["weight"],
      individual_tolerance: h["individual_tolerance"],
      added_in_draft: h["added_in_draft"]
    )
  end
end
