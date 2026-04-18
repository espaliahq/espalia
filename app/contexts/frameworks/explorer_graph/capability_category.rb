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
)
