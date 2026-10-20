# frozen_string_literal: true

# The discussion thread for ONE evidence linkage — lazily loaded into
# the evidence card's disclosure (see {Views::Assessments::Evidence::Card}).
#
# Interleaves the linkage's lifecycle rows (linked / valence changed /
# removed / withdrawn — muted, system-styled, no reply affordance) with
# the comment thread, chronologically, so the thread reads as the
# linkage's story. Comment rows reuse {Views::Assessments::Comments::Card}
# — same kebab, reply chips, tombstones, and `comments-thread` Stimulus
# contract as the cell thread.
#
# The thread anchors to the linkage's natural key, so it renders (and
# stays open for posting) after the link is removed — a state notice
# marks it. A withdrawn item's thread is read-only.
#
class Views::Assessments::Evidence::LinkThreadFrame < Views::Base
  include Views::Evidence::Valence
  include Phlex::Rails::Helpers::TimeAgoInWords

  # @param evidence_id [String]
  # @param capability_stable_id [String]
  # @param level_ordinal [Integer]
  # @return [String] the turbo-frame id for one linkage's thread
  def self.frame_id(evidence_id, capability_stable_id, level_ordinal)
    "evidence-link-thread-#{evidence_id}-#{capability_stable_id}-#{level_ordinal}"
  end

  # @param item [EvidenceItem]
  # @param assessment_id [String]
  # @param capability_stable_id [String]
  # @param level_ordinal [Integer]
  # @param comments [Array<PersonDevelopmentComment>] chronological, incl. deleted
  # @param lifecycle [Array<Assessments::EvidenceLinkThreadQuery::Entry>]
  # @param link [EvidenceLink, nil] current link row — nil/removed drives the notice
  # @param viewer_person_id [String]
  # @param can_comment [Boolean]
  # @param tenant_admin [Boolean]
  # @param error [String, nil] surfaced when a post/edit failed (frame redirect)
  def initialize(item:, assessment_id:, capability_stable_id:, level_ordinal:,
                 comments:, lifecycle:, link:, viewer_person_id:,
                 can_comment:, tenant_admin: false, error: nil)
    @item = item
    @assessment_id = assessment_id
    @capability_stable_id = capability_stable_id
    @level_ordinal = level_ordinal
    @comments = comments
    @lifecycle = lifecycle
    @link = link
    @viewer_person_id = viewer_person_id
    @can_comment = can_comment
    @tenant_admin = tenant_admin
    @error = error
  end

  def view_template
    turbo_frame_tag(self.class.frame_id(@item.id, @capability_stable_id, @level_ordinal)) do
      div(
        class: "mt-1 rounded-md border border-default " \
               "bg-subtle px-2 py-1.5",
        data: { controller: "comments-thread" }
      ) do
        error_line if @error.present?
        state_notice
        ul(class: "space-y-0.5") { render_rows }
        composer if composer_available?
      end
    end
  end

  private

  def composer_hint_id
    "link-comment-hint-#{@item.id}-#{@capability_stable_id}-#{@level_ordinal}"
  end

  def withdrawn?
    @item.withdrawn?
  end

  def link_removed?
    @link.nil? || @link.removed?
  end

  def composer_available?
    @can_comment && !withdrawn?
  end

  def error_line
    p(class: "mb-1 text-[11px] text-danger", role: "alert") { @error }
  end

  # Withdrawal wins over removal — it retracts the item itself, so the
  # thread is read-only. A removed link keeps the composer (the removal
  # is often the discussion's outcome and deserves a closing word).
  def state_notice
    if withdrawn?
      notice_text "This feedback was withdrawn — the discussion is read-only."
    elsif link_removed?
      notice_text "This feedback is no longer linked to this behaviour."
    end
  end

  def notice_text(text)
    p(class: "mb-1 text-[10px] italic text-muted") { text }
  end

  # One chronological stream: lifecycle rows + comment cards. The reply
  # chip logic mirrors Comments::Thread — a chip shows whenever the
  # answered comment isn't the row rendered directly above, which a
  # lifecycle row in between correctly counts as "not directly above".
  def render_rows
    previous_row = nil
    merged_rows.each do |kind, row|
      if kind == :lifecycle
        lifecycle_row(row)
      else
        parent = row.parent_id && comments_by_id[row.parent_id]
        reply_to = (parent if parent && previous_row != row.parent_id)
        render Views::Assessments::Comments::Card.new(
          comment: row,
          assessment_id: @assessment_id,
          can_edit: can_edit?(row),
          can_delete: can_delete?(row),
          can_reply: composer_available?,
          indent: row.parent_id.present?,
          reply_to: reply_to
        )
      end
      previous_row = (kind == :comment) ? row.id : nil
    end
  end

  # Tombstone rule from Comments::Thread: a deleted comment renders only
  # while some visible comment still replies to it.
  def merged_rows
    referenced = @comments.reject(&:deleted?).filter_map(&:parent_id).to_set
    visible = @comments.reject { |c| c.deleted? && !referenced.include?(c.id) }

    rows = visible.map { |c| [ c.posted_at.to_time, :comment, c ] } +
      @lifecycle.map { |e| [ (e.at || Time.at(0)).to_time, :lifecycle, e ] }
    rows.sort_by(&:first).map { |_, kind, row| [ kind, row ] }
  end

  def comments_by_id
    @comments_by_id ||= @comments.index_by(&:id)
  end

  # A withdrawn item's thread is read-only in full — no edits or deletes
  # either (the aggregate enforces the same; see
  # `ensure_comment_thread_mutable!`).
  def can_edit?(comment)
    !withdrawn? && !comment.deleted? && comment.author_id == @viewer_person_id
  end

  def can_delete?(comment)
    return false if withdrawn? || comment.deleted?

    comment.author_id == @viewer_person_id || @tenant_admin
  end

  # Muted system row — hollow dot, italic sentence, no kebab and no
  # reply affordance, so it can't be mistaken for a person's comment.
  def lifecycle_row(entry)
    li(class: "flex gap-2 py-1 text-[11px] text-muted") do
      span(
        class: "mt-1.5 w-2 h-2 rounded-full shrink-0 border border-current text-subtle",
        aria_hidden: "true"
      ) { }
      div(class: "min-w-0 flex-1 italic") do
        plain lifecycle_sentence(entry)
        if entry.at
          plain " · "
          span(title: entry.at.utc.iso8601) { "#{time_ago_in_words(entry.at)} ago" }
        end
      end
    end
  end

  def lifecycle_sentence(entry)
    actor = entry.actor_name.presence || "Someone"
    case entry.kind
    when :linked
      if (label = valence_label(entry.valence))
        "#{actor} linked this feedback as “#{label}”"
      else
        "#{actor} linked this feedback"
      end
    when :revalenced
      sentence = "#{actor} changed the valence to “#{valence_label(entry.valence)}”"
      if (was = valence_label(entry.previous_valence))
        sentence += " (was “#{was}”)"
      end
      sentence
    when :removed
      sentence = "#{actor} removed this feedback from this behaviour"
      sentence += " — #{entry.reason}" if entry.reason.present?
      sentence
    when :withdrawn
      sentence = "#{actor} withdrew this feedback"
      sentence += " — #{entry.reason}" if entry.reason.present?
      sentence
    end
  end

  # Always-visible composer — the viewer opened the discussion
  # deliberately, so no toggle dance like the cell thread's header "+".
  def composer
    form(
      action: assessment_comments_path(@assessment_id),
      method: "post",
      class: "mt-1.5",
      data: { action: "turbo:submit-end->comments-thread#submitted" }
    ) do
      input(type: "hidden", name: "authenticity_token",
            value: view_context.form_authenticity_token)
      input(type: "hidden", name: "comment[capability_stable_id]",
            value: @capability_stable_id)
      input(type: "hidden", name: "comment[level_ordinal]", value: @level_ordinal)
      input(type: "hidden", name: "comment[evidence_id]", value: @item.id)

      textarea(
        name: "comment[body]",
        rows: 2,
        required: true,
        placeholder: "Discuss this feedback's relevance to this behaviour…",
        aria: { label: "Comment on this feedback linkage", describedby: composer_hint_id },
        class: Components::Kit::Field::INLINE,
        data: {
          comments_thread_target: "composerBody",
          action: "keydown->comments-thread#submitOnModEnter"
        }
      ) { "" }

      div(class: "mt-1 flex items-center justify-between gap-2") do
        span(id: composer_hint_id, class: "text-[10px] text-muted") do
          plain "#{Prose::COMPOSER_HINT} · ⌘/Ctrl+Enter to post"
        end
        render Components::Kit::Button.new(tone: :brand, size: :xs, type: :submit) { "Post" }
      end
    end
  end
end
