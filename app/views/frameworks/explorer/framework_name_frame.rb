# frozen_string_literal: true

# Turbo Frame wrapping the framework's name in the explorer header — the page's
# `<h1>` — plus, for a viewer who may rename it, the inline-edit affordance.
# Rendered in place by {Views::Frameworks::ShowView#framework_header} and as the
# PATCH response from {Frameworks::NamesController#update}, so Turbo swaps the
# name in place.
#
# A framework rename is a **direct edit** (not the suggested-edit path), like
# the org-structure renames in §11 of framework-explorer.md: no pending
# decoration, no Editing/Suggesting interaction, the editor always says "Save".
# The pencil renders in :edit mode for a viewer with `can_rename`
# (`FrameworkPolicy#rename?`, see authorization.md); everyone else gets the
# plain heading, byte-for-byte what it was before renaming existed.
#
# The editor host is a `<div>` around the heading rather than the heading
# itself: the shared editor appends its cloned `<form>` to the host, and a
# form is not phrasing content, so it must not land inside an `<h1>`.
#
class Views::Frameworks::Explorer::FrameworkNameFrame < Views::Base
  include Phlex::Rails::Helpers::TurboFrameTag
  include Views::Frameworks::Explorer::Concerns::HoverCluster
  include Views::Frameworks::Explorer::Concerns::InlineEditable

  # @param framework_id [String]
  # @param name [String] the current name
  # @param mode [Symbol] :view or :edit
  # @param can_rename [Boolean] FrameworkPolicy#rename? for the viewer; the
  #   frame owns the mode gate (like its sibling frames), so pass the raw flag
  # @param error [String, nil] a rejected inline save (Hard-Won Lesson 26 — the
  #   422 must carry the frame, the message, and the attempted text)
  # @param attempted_value [String, nil] the value the rejected save carried
  def initialize(framework_id:, name:, mode: :view, can_rename: false, error: nil, attempted_value: nil)
    @framework_id = framework_id
    @name = name
    @mode = mode
    @can_rename = can_rename
    @error = error
    @attempted_value = attempted_value
  end

  def view_template
    turbo_frame_tag("framework-name-#{@framework_id}", class: "min-w-0 max-w-full") do
      if editable?
        editable
      else
        heading
      end
    end
  end

  private

  def editable?
    @mode == :edit && @can_rename
  end

  def heading
    h1(class: "min-w-0 max-w-full truncate text-xl sm:text-2xl font-bold text-gray-900 dark:text-white",
       title: @name) { @name }
  end

  # The heading keeps its width (the shared editor pins the form to the host's
  # pre-open width — Lesson 27 — so a block-level host hands it the full line).
  # The pencil is `standalone`: the header has no kebab for it to collapse
  # into on a coarse pointer, so it stays visible there instead.
  def editable
    div(class: "flex min-w-0 max-w-full flex-col items-start gap-1",
        data: hover_cluster_data("hdr").merge(editor_data)) do
      # Pencil hugs the text (phlex-views.md, inline-edit affordances); centred
      # rather than top-aligned because a 2xl heading is far taller than the glyph.
      div(class: "flex min-w-0 max-w-full items-center gap-1", data: { editor_display: true }) do
        heading
        render_inline_editor_pencil(aria_label: "Edit framework name", scope: "hdr", collapses: false)
      end
      render_field_editor_error(@error)
    end
  end

  # Direct edit — no approval tier, so the editor always says "Save". After a
  # rejected save the editor re-opens seeded with the attempted text, so
  # nothing typed is lost.
  def editor_data
    field_editor_data(
      action: framework_name_path(framework_id: @framework_id),
      field: "framework[name]",
      value: (@error ? @attempted_value : @name).to_s,
      label: "Framework name",
      outcome: "apply",
      rows: 1,
      error: @error
    )
  end
end
