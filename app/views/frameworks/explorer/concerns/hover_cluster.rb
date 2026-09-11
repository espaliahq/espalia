# frozen_string_literal: true

# The ONE hover-cluster rule for the explorer grid (#380).
#
# Before this, every hover control had its own reveal scope — the capability
# pencil on the name span (`group/ine`), the row kebab on the whole row
# (`group`), the cell's Discuss bubble on the cell (`group/cell`), the
# illustration controls on the item (`group/ill`) — so controls popped in at
# different moments as the pointer moved across one row.
#
# Now an entity's row / cell / item carries `data-hover-cluster="<scope>"` and
# every control in its cluster carries `data-cluster="<scope> inline|kebab"`.
# One CSS rule set in `app/assets/tailwind/application.css` pairs them, so:
#
# - hovering (or focusing into) the entity reveals its WHOLE cluster at once;
# - a nested scope reveals independently (a cell's cluster does not pop when
#   the pointer is elsewhere in the row, while the row's cluster does);
# - `pointer-coarse` collapses the cluster to the kebab alone, which is why
#   every kebab also carries the cluster's Edit… / Discuss… as menu items.
#
# It also removes the Tailwind `group-hover/<token>` interpolation hazard
# (Hard-Won Lesson 12) from these call sites entirely — there is no class name
# to build, only a scope name.
#
# Fixed order: **pencil · discuss · kebab**. `render_hover_cluster` renders the
# controls it is given in that order; where the pencil belongs to the entity's
# own Turbo Frame (a capability name, a category name, an expectation text —
# the frame re-render has to carry it, and the shared editor resolves its host
# by `closest("[data-editor-action]")`), that frame renders the pencil itself
# via `render_inline_editor_pencil(scope:)` immediately before this cluster.
module Views::Frameworks::Explorer::Concerns::HoverCluster
  # row · cell · ill · cat are the grid; tree is the role pane, hdr the matrix
  # header (a level title). Each needs its own CSS pair — see application.css.
  SCOPES = %w[row cell ill cat tree hdr].freeze

  # How a control behaves when the cluster collapses on a coarse pointer:
  #
  #   kebab       the ⋮ — stays visible and carries the rest as menu items
  #   inline      collapses into that kebab (which MUST offer the same action)
  #   standalone  an inline control whose cluster has NO kebab, so it has
  #               nowhere to collapse to and stays visible instead
  #
  # `standalone` is not a style choice: hiding a control with no fallback makes
  # it unreachable on touch (the level-title and org-structure renames, and the
  # pending ghosts' amend pencil, were exactly that). The invariant — every
  # `inline` control shares its cluster with a `kebab` — is pinned by
  # `explorer_menu_system_test.rb`.
  CONTROL_KINDS = %w[kebab inline standalone].freeze

  # @param scope [String] one of {SCOPES}
  # @return [Hash] data attributes for the entity that owns the cluster
  def hover_cluster_data(scope)
    { hover_cluster: assert_cluster_scope(scope) }
  end

  # @param scope [String]
  # @param kind [String] one of {CONTROL_KINDS}
  # @return [Hash] data attributes for one control in the cluster
  def cluster_control_data(scope, kind = "inline")
    unless CONTROL_KINDS.include?(kind)
      raise ArgumentError, "unknown cluster control kind #{kind.inspect}"
    end

    { cluster: "#{assert_cluster_scope(scope)} #{kind}" }
  end

  # Renders the cluster's controls in the fixed order pencil · discuss · kebab.
  #
  # @param scope [String]
  # @param pencil [Hash, nil] `{ aria_label:, collapses: }` — omit when the
  #   entity's own Turbo Frame renders the pencil (see the module comment)
  # @param discuss [Hash, nil] the {DiscussTrigger} anchor plus `label:`
  # @param menu [Hash, nil] `{ label:, nodes: }` for {MenuItems#render_menu_trigger}
  # @return [void]
  def render_hover_cluster(scope:, pencil: nil, discuss: nil, menu: nil)
    render_inline_editor_pencil(scope: scope, **pencil) if pencil
    render_discuss_button(scope: scope, **discuss) if discuss
    render_menu_trigger(scope: scope, **menu) if menu
  end

  # The ONE "add" affordance — a dashed ghost, always visible in edit mode, for
  # every add in the grid (category, capability, expectation, illustration).
  # Always visible rather than hover-revealed so it is keyboard reachable and
  # discoverable on a touch device; dashed and muted so it never competes with
  # the content above it.
  #
  # @param label [String] e.g. "Add expectation"
  # @param data [Hash] the trigger's data attributes (a modal open, or the
  #   shared field editor's `field-editor#open`)
  # @return [void]
  def render_add_affordance(label, **data)
    button(type: "button", class: "explorer-add", data: data) do
      icon("plus")
      span { label }
    end
  end

  private

  def assert_cluster_scope(scope)
    raise ArgumentError, "unknown hover-cluster scope #{scope.inspect}" unless SCOPES.include?(scope)

    scope
  end
end
