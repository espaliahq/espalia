# frozen_string_literal: true

# The two header affordances a **shape-changing** write flips: the `vN draft`
# pill next to the framework name, and the Publish button in the action
# cluster. Both live outside the matrix Turbo Frame. The projection
# broadcasts them whenever a draft opens or closes
# (BroadcastsFrameworkActivity#broadcast_draft_status), so no write path has
# to remember to; the write-response streams only give the actor the same
# answer without waiting on ActionCable.
#
# Rendered as two addressable slots rather than one block because they sit at
# opposite ends of the header row; the shared class keeps their "is there a
# draft?" rule in one place.
#
class Views::Frameworks::Explorer::DraftStatus < Views::Base
  BADGE_ID = "framework-draft-badge"
  PUBLISH_ID = "framework-publish-action"
  # Only viewers with publish rights when the page loaded subscribe, so a
  # broadcast Publish button doesn't reach suggest-only collaborators. Rights
  # that change mid-session take effect on the next load, in either direction.
  PUBLISHERS_STREAM = "framework_publishers"

  # @param framework [FrameworkState::Framework, Frameworks::ExplorerGraph::Framework]
  # @param slot [Symbol] :badge (the draft pill) or :publish (the Publish button)
  # @param visible [Boolean] whether this viewer sees the slot at all — edit
  #   mode for the pill, edit mode + publish rights for the button. A hidden
  #   slot still renders its (empty) anchor so a later stream can find it.
  # @param publishing [Boolean] a publish of this draft is queued or running
  #   ({FrameworkPublication.publishing?}) — the button renders disabled so
  #   nobody requests it twice.
  def initialize(framework:, slot:, visible: true, publishing: false)
    @framework = framework
    @slot = slot
    @visible = visible
    @publishing = publishing
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
    return publishing_button if @publishing

    render Components::Kit::Button.new(
      tone: :brand, size: :sm, href: new_framework_publication_path(@framework.framework_id),
      title: "Review and publish v#{@framework.draft_version}"
    ) { "Publish v#{@framework.draft_version}" }
  end

  # The publish is already running in the background: same footprint as the
  # button so the header doesn't jump, but a real disabled control (not a link
  # styled dead) so keyboard and screen-reader users get the state too. Opaque
  # neutral surface — the label is the only thing saying a publish is in flight.
  def publishing_button
    render Components::Kit::Button.new(
      tone: :brand, size: :sm, disabled: true, aria: { disabled: "true" },
      title: "v#{@framework.draft_version} is being published — you'll be notified when it's live"
    ) { "Publishing v#{@framework.draft_version}…" }
  end
end
