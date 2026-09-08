# frozen_string_literal: true

# The one definition of "this capability is staged for archive in the open
# draft" for the matrix components, and the strikethrough that marks its rows.
#
# Graph capabilities carry `pending_archive`; AR read-model capabilities don't
# respond to it (they're published by construction), hence the `respond_to?`.
module Views::Frameworks::Explorer::Concerns::PendingArchive
  # Red line-through across a whole row. Applied to each cell (`[&>td]`)
  # rather than the <tr>, because text-decoration doesn't reliably propagate
  # from a table-row to its cells.
  STRIKETHROUGH_CLASSES = "[&>td]:line-through [&>td]:decoration-red-400 [&>td]:decoration-2"

  # @param capability [FrameworkState::Capability, Frameworks::ExplorerGraph::Capability]
  # @return [Boolean]
  def pending_archive?(capability)
    capability.respond_to?(:pending_archive) && !!capability.pending_archive
  end

  # Edit mode only — view mode shows the capability un-struck (it's still in
  # the published version until publish).
  #
  # @return [Boolean]
  def struck?(capability, mode)
    mode == :edit && pending_archive?(capability)
  end
end
