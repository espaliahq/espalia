# frozen_string_literal: true

# The grid's kebab triggers (#380).
#
# Every ⋮ in the matrix used to be a whole `Kit::Dropdown`: a wrapper div with
# its own `dropdown` Stimulus mount, a hidden `role="menu"` panel, and each item
# pre-rendered with its ~200-byte class string — for a menu the user opens maybe
# once a session. Now the server emits a bare trigger carrying only the ids and
# permission flags its menu needs, and `explorer_menu_controller.js` (mounted
# ONCE on the explorer root) composes the items on open. Everything else the
# menu needs it reads from coordinates the grid already publishes —
# `tr[data-capability-id]`, `tr[data-capability-name]`, `tr[data-category-id]`,
# `[data-reorder-item-id]` — so nothing is duplicated per cell.
#
# Authority stays server-side: a viewer who cannot approve simply never receives
# the suggestion id, so the builder has no approve/reject pair to compose (see
# {Frameworks::SuggestionApprovalAuthority}).
module Views::Frameworks::Explorer::Concerns::MenuItems
  # The kebab trigger is a hover-cluster member, so every host needs the
  # cluster's data helpers.
  def self.included(base)
    super
    base.include(Views::Frameworks::Explorer::Concerns::HoverCluster)
  end

  # The hover-revealed ⋮ trigger — one definition of the glyph and hit target so
  # the grid's kebabs can't drift apart.
  #
  # `.explorer-kebab` carries the chrome as ONE class rather than ~200 bytes of
  # utilities, because it repeats on every expectation cell, capability row,
  # category header and illustration.
  #
  # @param scope [String] the hover-cluster scope (see {HoverCluster})
  # @param label [String] accessible name — also the open menu's aria-label
  # @param kind [String] `data-menu` — selects the client-side item builder
  # @param menu [Hash] `data-menu-*` values (compacted); see the builders in
  #   `explorer_menu_controller.js` for what each kind consumes
  # @return [void]
  def render_menu_trigger(scope:, label:, kind:, **menu)
    button(
      type: "button",
      aria: { haspopup: "true", expanded: "false", label: label },
      class: "explorer-kebab",
      data: cluster_control_data(scope, "kebab")
              .merge(action: "explorer-menu#toggle", menu: kind)
              .merge(menu.transform_keys { |key| :"menu_#{key}" })
              .compact
    ) do
      icon("kebab", class: "w-4 h-4")
    end
  end

  # `data-menu-*` for one pending suggestion the viewer may approve. The
  # client-side builder turns the id + preview into the Approve (inline POST)
  # and Reject (shared modal) pair — the §12 actionable pattern.
  #
  # @param descriptor [Hash, nil] `{ suggestion_id:, suggested_value: }`
  # @param prefix [String] "" for a lone suggestion, "name_"/"desc_" when an
  #   entity can carry more than one (a capability's name AND description)
  # @return [Hash]
  def approval_menu_data(descriptor, prefix: "")
    return {} if descriptor.blank? || descriptor[:suggestion_id].blank?

    {
      "#{prefix}sid": descriptor[:suggestion_id],
      "#{prefix}preview": descriptor[:suggested_value].to_s
    }
  end
end
