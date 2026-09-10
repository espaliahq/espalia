# frozen_string_literal: true

# The two header affordances a **shape-changing** write flips: the `vN draft`
# pill next to the framework name, and the Publish button in the action
# cluster. Both live outside the matrix Turbo Frame, so a write that
# auto-opens a draft (add capability, add level, archive) has to stream them
# explicitly — otherwise the header silently lies until the next full load.
#
# Rendered as two addressable slots rather than one block because they sit at
# opposite ends of the header row; the shared class keeps their "is there a
# draft?" rule in one place.
#
class Views::Frameworks::Explorer::DraftStatus < Views::Base
  BADGE_ID = "framework-draft-badge"
  PUBLISH_ID = "framework-publish-action"

  # @param framework [FrameworkState::Framework, Frameworks::ExplorerGraph::Framework]
  # @param slot [Symbol] :badge (the draft pill) or :publish (the Publish button)
  # @param visible [Boolean] whether this viewer sees the slot at all — edit
  #   mode for the pill, edit mode + publish rights for the button. A hidden
  #   slot still renders its (empty) anchor so a later stream can find it.
  def initialize(framework:, slot:, visible: true)
    @framework = framework
    @slot = slot
    @visible = visible
  end

  def view_template
    case @slot
    when :badge then span(id: BADGE_ID) { draft_badge if render_content? }
    when :publish then span(id: PUBLISH_ID) { publish_button if render_content? }
    end
  end

  private

  def render_content? = @visible && @framework.draft?

  # Draft status pill — teal, distinct from the blue published-version badge
  # and the amber edit-mode badge. Drafts are the normal working state, so this
  # is an ambient status, not a warning.
  def draft_badge
    render Components::Kit::Badge.new("v#{@framework.draft_version} draft", variant: :primary)
  end

  # Links to the publish-review page, where the as-we-go migration mappings are
  # validated before the version is cut — the deliberate confirmation step, and
  # the ONE edit-mode action that stays a full navigation.
  def publish_button
    a(
      href: new_framework_publication_path(@framework.framework_id),
      class: "inline-flex items-center gap-1.5 rounded-sm px-3 py-1.5 text-sm font-semibold " \
             "bg-primary text-white hover:bg-primary/90 transition-colors",
      title: "Review and publish v#{@framework.draft_version}"
    ) { "Publish v#{@framework.draft_version}" }
  end
end
