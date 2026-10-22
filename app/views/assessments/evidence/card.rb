# frozen_string_literal: true

# Renders a single evidence item inside one expanded cell of an
# assessment matrix.
#
# Shows source dot (self/manager/peer), type label, optional title,
# content, optional external-link chip, author + relative timestamp, and —
# when the item is attached to more than one cell — an "also linked to N
# other places" indicator. A hover-revealed action menu lets the author or
# anyone in the assessee's manager chain link the item to another
# capability, remove it from THIS cell (greyed out when it's the item's
# only link), or withdraw it everywhere.
#
class Views::Assessments::Evidence::Card < Views::Base
  include Phlex::Rails::Helpers::TimeAgoInWords
  include Phlex::Rails::Helpers::ButtonTo
  include Views::Evidence::Valence

  SOURCE_DOT = {
    "self"    => "bg-activity-self",
    "manager" => "bg-activity-manager",
    "peer"    => "bg-activity-peer"
  }.freeze

  TYPE_LABEL = {
    "peer_feedback"     => "Peer feedback",
    "manager_feedback"  => "Manager feedback",
    "customer_feedback" => "Customer feedback",
    "impact"            => "Impact",
    "project_outcome"   => "Project outcome",
    "code_review"       => "Code review",
    "design_review"     => "Design review",
    "incident_response" => "Incident response",
    "presentation"      => "Presentation",
    "mentoring"         => "Mentoring",
    "observation"       => "Observation",
    "other"             => nil
  }.freeze

  CHIP_CLASSES = "inline-flex items-center gap-0.5 rounded bg-gray-100 dark:bg-gray-700 " \
                 "px-1.5 py-0.5 text-[10px] text-gray-600 dark:text-gray-300"

  # @param item [EvidenceItem]
  # @param assessment_id [String] for routing the actions
  # @param current_capability_stable_id [String] the cell this card renders in
  # @param current_level_ordinal [Integer] the cell this card renders in
  # @param can_withdraw [Boolean] whether the current viewer may withdraw this item
  # @param can_manage_links [Boolean] whether the current viewer may add/remove this item's links
  # @param can_update [Boolean] whether the current viewer may edit this item
  def initialize(item:, assessment_id:, current_capability_stable_id:, current_level_ordinal:,
                 can_withdraw: false, can_manage_links: false, can_update: false)
    @item = item
    @assessment_id = assessment_id
    @current_capability_stable_id = current_capability_stable_id
    @current_level_ordinal = current_level_ordinal
    @can_withdraw = can_withdraw
    @can_manage_links = can_manage_links
    @can_update = can_update
  end

  def view_template
    li(
      id: "evidence-#{@item.id}",
      class: "group relative flex gap-2 py-1.5 text-xs text-gray-700 dark:text-gray-200"
    ) do
      source_dot
      div(class: "min-w-0 flex-1") do
        header_line
        title_line if @item.title.present?
        content_line
        also_linked_line if other_link_count.positive?
        footer_line
        discussion_disclosure
      end
      actions_menu if @can_withdraw || @can_manage_links || @can_update
    end
  end

  private

  # Active links other than the cell this card is rendered in.
  def other_link_count
    count = @item.active_link_count
    return 0 if count.nil?

    [ count - 1, 0 ].max
  end

  # Whether "unlink from this capability" is allowed: managing links is permitted
  # AND this is not the item's only link (the last-link invariant — an
  # active item must keep ≥1 link — is also enforced in the aggregate).
  def can_remove_this_link?
    @can_manage_links && @item.active_link_count.to_i > 1
  end

  def also_linked_line
    div(class: "mt-1 text-[10px] text-gray-500 dark:text-gray-400 italic") do
      n = other_link_count
      plain "Also linked to #{n} other #{n == 1 ? 'place' : 'places'}"
    end
  end

  # Collapsed count-plus-excerpt affordance for this LINKAGE's discussion
  # thread (per cell, not per item — the same item carries an independent
  # thread in each cell it's linked to). A native <details> keeps the
  # toggle JS-free; the turbo frame inside is `loading: "lazy"`, so the
  # thread (comments + stream-read lifecycle rows) is only fetched when
  # the disclosure opens and the frame becomes visible.
  #
  # `frame-error` is mounted on THIS disclosure, not the card list: many
  # cards render per page, and each instance must own exactly one frame and
  # its own error block (audit issue #365) — a failed GET otherwise leaves
  # "Loading discussion…" standing forever with no retry.
  def discussion_disclosure
    details(class: "mt-1", data: { controller: "frame-error" }) do
      summary(
        class: "cursor-pointer list-none [&::-webkit-details-marker]:hidden " \
               "inline-flex max-w-full min-h-6 items-center gap-1 rounded px-1 -mx-1 py-0.5 " \
               "text-[10px] text-gray-600 dark:text-gray-300 " \
               "hover:bg-gray-100 hover:text-gray-700 dark:hover:bg-gray-700/60 " \
               "dark:hover:text-gray-200 transition-colors"
      ) do
        discussion_glyph
        if discussion_count.positive?
          span(class: "font-medium shrink-0") do
            "#{discussion_count} #{'comment'.pluralize(discussion_count)}"
          end
          if discussion_stats[:latest_body].present?
            span(class: "truncate italic") { "· “#{discussion_stats[:latest_body]}”" }
          end
        else
          span { "Discuss" }
        end
      end
      turbo_frame_tag(thread_frame_id, src: thread_frame_src, loading: "lazy",
                      data: { frame_error_target: "frame" }) do
        div(class: "py-1 text-[10px] italic text-gray-600 dark:text-gray-300") do
          "Loading discussion…"
        end
      end
      # No Close: this is not a modal — collapsing the disclosure is the exit.
      render Components::Shared::FrameLoadError.new(
        id: "#{thread_frame_id}-error", subject: "the discussion", classes: "py-1 space-y-2"
      )
    end
  end

  def discussion_stats
    @discussion_stats ||=
      @item.link_comment_stats&.[]([ @current_capability_stable_id, @current_level_ordinal.to_i ]) || {}
  end

  def discussion_count
    discussion_stats[:count].to_i
  end

  def thread_frame_id
    Views::Assessments::Evidence::LinkThreadFrame.frame_id(
      @item.id, @current_capability_stable_id, @current_level_ordinal
    )
  end

  def thread_frame_src
    assessment_evidence_link_thread_path(
      @assessment_id, @item.id,
      capability_stable_id: @current_capability_stable_id,
      level_ordinal: @current_level_ordinal
    )
  end

  def discussion_glyph
    svg(
      class: "w-3 h-3 shrink-0",
      fill: "none",
      viewBox: "0 0 24 24",
      stroke: "currentColor",
      stroke_width: "2",
      aria_hidden: "true"
    ) do |s|
      s.path(
        stroke_linecap: "round",
        stroke_linejoin: "round",
        d: "M8 12h.01M12 12h.01M16 12h.01M21 12c0 4.418-4.03 8-9 8a9.863 " \
           "9.863 0 01-4.255-.949L3 20l1.395-3.72C3.512 15.042 3 13.574 3 12 " \
           "3 7.582 7.03 4 12 4s9 3.582 9 8z"
      )
    end
  end

  def source_dot
    color = SOURCE_DOT[@item.source] || "bg-activity-cleared"
    span(
      class: "mt-1 w-2 h-2 rounded-full shrink-0 #{color}",
      title: @item.source.to_s.capitalize
    ) { }
  end

  def header_line
    div(class: "flex flex-wrap items-center gap-x-2 gap-y-0.5 text-[11px]") do
      span(class: "font-medium text-gray-600 dark:text-gray-300") do
        type_label
      end
      # THIS cell's link valence (per-link, so the same item can read
      # "Demonstrates" in one cell and "Growth area" in another). No badge
      # for pre-valence links — unclassified stays visually quiet.
      valence_badge(cell_valence)
      if @item.external_reference&.imported?
        render Views::Evidence::OriginBadge.new(@item.external_reference)
      elsif @item.external_reference&.present?
        external_chip
      end
      @item.exchange_acks&.each { |ack| also_in_chip(ack) }
    end
  end

  def cell_valence
    @item.link_valences&.[]([ @current_capability_stable_id, @current_level_ordinal.to_i ])
  end

  def title_line
    p(class: "font-medium text-gray-900 dark:text-gray-100 mt-0.5") { @item.title }
  end

  # The card only renders inside the focused expanded cell (the capability
  # card's expansion panel renders for one level at a time — see
  # assessments.md, "Full illustrations and evidence are reserved for the
  # focused cell"). When the card is on screen the
  # user has explicitly focused this cell, so render the full content —
  # clamping to two lines hides the very text they came to read.
  def content_line
    render Components::Kit::Prose.new(@item.content, class: "mt-0.5 text-gray-700 dark:text-gray-300")
  end

  def footer_line
    div(class: "mt-1 text-[10px] text-gray-600 dark:text-gray-300") do
      span { @item.author&.name || "Unknown" }
      plain " · "
      span { @item.recorded_at ? "#{time_ago_in_words(@item.recorded_at)} ago" : "—" }
      if @item.edited_at.present?
        plain " · "
        span(title: "Last edited #{@item.edited_at.utc.iso8601}") do
          "edited #{time_ago_in_words(@item.edited_at)} ago"
        end
      end
    end
  end

  def type_label
    if @item.evidence_type == "other"
      @item.custom_type_label.presence || "Other"
    else
      TYPE_LABEL[@item.evidence_type] || @item.evidence_type.to_s.humanize
    end
  end

  def external_chip
    ref = @item.external_reference
    label = ref.system.presence || "link"
    safe_url = ref.safe_url
    if safe_url
      a(href: safe_url, target: "_blank", rel: "noopener noreferrer",
        class: "inline-flex items-center gap-0.5 rounded bg-gray-100 dark:bg-gray-700 " \
               "px-1.5 py-0.5 text-[10px] text-gray-600 dark:text-gray-300 hover:bg-gray-200 " \
               "dark:hover:bg-gray-600 hover:underline") { label }
    else
      span(class: "inline-flex items-center gap-0.5 rounded bg-gray-100 dark:bg-gray-700 " \
                 "px-1.5 py-0.5 text-[10px] text-gray-600 dark:text-gray-300") { label }
    end
  end

  # Where a peer feedback system says it also holds this item ("Also in Chip").
  # The link is the peer's own address, so it is opened in a new tab.
  def also_in_chip(ack)
    label = "Also in #{ack.consumer.titleize}"
    url = ack.safe_remote_url
    if url
      a(href: url, target: "_blank", rel: "noopener noreferrer", class: CHIP_CLASSES + " hover:bg-gray-200 dark:hover:bg-gray-600 hover:underline",
        data: { exchange_ack: ack.consumer }) do
        plain label
        span(class: "sr-only") { " (opens in a new tab)" }
      end
    else
      span(class: CHIP_CLASSES, data: { exchange_ack: ack.consumer }) { label }
    end
  end

  # Hover-revealed kebab menu that hosts Edit, link management
  # (Link to another capability / Unlink from this capability), and Withdraw.
  #
  # The wrapper stays opacity-100 while the menu is open (`aria-expanded` on
  # the trigger) so it doesn't fade out when the cursor leaves the card.
  def actions_menu
    div(
      class: "absolute top-1 right-1 opacity-0 group-hover:opacity-100 pointer-coarse:opacity-100 " \
             "focus-within:opacity-100 has-[[aria-expanded=true]]:opacity-100 transition-opacity"
    ) do
      render Components::Kit::Dropdown.new do |dropdown|
        kebab_trigger
        dropdown.menu(width: "w-44") do
          edit_menu_item if @can_update
          # The author's Edit already manages links (the unified modal). Offer a
          # link-only entry only to non-author link-holders (content disabled there).
          link_menu_item if @can_manage_links && !@can_update
          remove_link_menu_item if @can_manage_links
          withdraw_menu_item if @can_withdraw
        end
      end
    end
  end

  def kebab_trigger
    render Components::Kit::Button.new(
      variant: :ghost, size: :xs, icon: true, aria_label: "Feedback / evidence actions",
      data: { dropdown_target: "trigger", action: "dropdown#toggle" },
      aria: { haspopup: "menu", expanded: "false" }
    ) { icon("kebab", class: "size-4") }
  end

  def edit_menu_item
    modal_menu_button("Edit")
  end

  # Opens the unified modal in edit mode for a non-author who may manage links
  # but not edit content — the server disables the content fields, leaving the
  # "Applies to" block active.
  def link_menu_item
    modal_menu_button("Link to another capability")
  end

  def modal_menu_button(label)
    button(
      type: "button",
      class: "block w-full text-left px-3 py-1.5 text-xs text-default hover:bg-default-hover",
      role: "menuitem",
      data: {
        action: "click->dropdown#close evidence-modal#load click->modal#open",
        modal_target_id: "evidence-modal-overlay",
        evidence_modal_mode_param: "edit",
        evidence_modal_evidence_id_param: @item.id,
        # The entry point: the cell this card sits in. Its "Applies to" row
        # sorts first + highlights so the modal opens oriented to where the
        # user came from.
        evidence_modal_capability_stable_id_param: @current_capability_stable_id,
        evidence_modal_level_ordinal_param: @current_level_ordinal,
        evidence_modal_return_to_param: "assessment:#{@assessment_id}"
      }
    ) { label }
  end

  # "Unlink from this capability" — removes the link for the cell this card
  # is rendered in. Greyed out (non-interactive) when this is the item's only
  # link: removing it is forbidden (withdraw instead). The aggregate is the
  # backstop for the same invariant.
  def remove_link_menu_item
    if can_remove_this_link?
      button_to(
        remove_link_assessment_evidence_path(@assessment_id, @item.id),
        params: { evidence: { capability_stable_id: @current_capability_stable_id,
                              level_ordinal: @current_level_ordinal } },
        method: :post,
        class: "block w-full text-left px-3 py-1.5 text-xs text-default hover:bg-default-hover",
        role: "menuitem",
        form: { data: { turbo_confirm: unlink_confirm_message } }
      ) { "Unlink from this capability" }
    else
      span(
        class: "block w-full text-left px-3 py-1.5 text-xs text-disabled cursor-not-allowed",
        role: "menuitem",
        aria: { disabled: "true" },
        title: "This is the only place this feedback is linked — withdraw it instead."
      ) { "Unlink from this capability" }
    end
  end

  # An unlink with an active discussion shouldn't surprise anyone — the
  # confirm discloses the thread and that it survives (the thread anchors
  # to the linkage's natural key, so it is preserved, not deleted).
  def unlink_confirm_message
    base = "Unlink this feedback from this capability?"
    return base if discussion_count.zero?

    "#{base} Its discussion (#{discussion_count} " \
      "#{'comment'.pluralize(discussion_count)}) will be kept in history."
  end

  def withdraw_menu_item
    button_to(
      assessment_evidence_path(@assessment_id, @item.id),
      method: :delete,
      class: "block w-full text-left px-3 py-1.5 text-xs text-danger hover:bg-danger-subtle",
      role: "menuitem",
      form: { data: { turbo_confirm: "Withdraw this feedback?" } }
    ) { "Withdraw" }
  end
end
