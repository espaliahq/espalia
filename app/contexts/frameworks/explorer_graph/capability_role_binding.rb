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
)
