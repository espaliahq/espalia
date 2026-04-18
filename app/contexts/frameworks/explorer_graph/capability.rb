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
)
