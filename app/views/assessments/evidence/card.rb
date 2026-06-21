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

  SOURCE_DOT = {
    "self"    => "bg-emerald-500",
    "manager" => "bg-indigo-500",
    "peer"    => "bg-amber-500"
  }.freeze

  TYPE_LABEL = {
    "peer_feedback"     => "Peer feedback",
    "project_outcome"   => "Project outcome",
    "code_review"       => "Code review",
    "design_review"     => "Design review",
    "customer_feedback" => "Customer feedback",
    "incident_response" => "Incident response",
    "presentation"      => "Presentation",
    "mentoring"         => "Mentoring",
    "observation"       => "Observation",
    "other"             => nil
  }.freeze

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

  def source_dot
    color = SOURCE_DOT[@item.source] || "bg-gray-400"
    span(
      class: "mt-1 w-2 h-2 rounded-full shrink-0 #{color}",
      title: @item.source.to_s.capitalize
    ) { }
  end

  def header_line
    div(class: "flex flex-wrap items-center gap-x-2 text-[11px]") do
      span(class: "font-medium text-gray-600 dark:text-gray-300") do
        type_label
      end
      external_chip if @item.external_reference&.present?
    end
  end

  def title_line
    p(class: "font-medium text-gray-900 dark:text-gray-100 mt-0.5") { @item.title }
  end

  # The card only renders inside the focused expanded cell (see
  # assessment_row.rb's `group-data-[focused=true]/assess-expanded:block`
  # gate, and assessments.md "Full illustrations and evidence are
  # reserved for the focused cell"). When the card is on screen the
  # user has explicitly focused this cell, so render the full content —
  # clamping to two lines hides the very text they came to read.
  # `whitespace-pre-wrap` preserves any line breaks the author entered.
  def content_line
    p(class: "mt-0.5 text-gray-700 dark:text-gray-300 whitespace-pre-wrap break-words") do
      @item.content
    end
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

  # Hover-revealed kebab menu that hosts Edit, link management
  # (Link to another capability / Unlink from this capability), and Withdraw.
  # Uses the shared `dropdown`
  # Stimulus controller — same one the user menu and framework explorer
  # use — so behaviour (click-outside close, transition, aria) is
  # consistent across the app.
  #
  # The wrapper goes opacity-100 when the dropdown is open (driven by
  # the `aria-expanded` Stimulus controller toggles on the trigger)
  # via `has-[]` so the menu doesn't fade-out the moment the user
  # clicks the kebab and the cursor leaves the hover area.
  def actions_menu
    div(
      class: "absolute top-1 right-1 opacity-0 group-hover:opacity-100 " \
             "focus-within:opacity-100 has-[[aria-expanded=true]]:opacity-100 transition-opacity",
      data: { controller: "dropdown",
              action: "keydown.esc@window->dropdown#close" }
    ) do
      kebab_trigger
      kebab_menu
    end
  end

  def kebab_trigger
    button(
      type: "button",
      class: "rounded p-1 text-gray-400 hover:text-gray-700 hover:bg-gray-100 " \
             "dark:hover:bg-gray-700 dark:hover:text-gray-200",
      data: { dropdown_target: "trigger", action: "dropdown#toggle" },
      aria: { label: "Evidence actions", haspopup: "menu", expanded: "false" }
    ) do
      # Vertical 3-dot kebab — kept inline so we don't depend on an icon set.
      span(class: "block leading-none -mt-1 text-base", aria_hidden: "true") { "⋮" }
    end
  end

  def kebab_menu
    div(
      class: "hidden absolute right-0 mt-1 w-44 rounded-md border border-gray-200 " \
             "dark:border-gray-700 bg-white dark:bg-gray-900 shadow-lg z-10 " \
             "py-1 text-xs",
      role: "menu",
      data: { dropdown_target: "menu" }
    ) do
      edit_menu_item if @can_update
      # The author's Edit already manages links (the unified modal). Offer a
      # link-only entry only to non-author link-holders (content disabled there).
      link_menu_item if @can_manage_links && !@can_update
      remove_link_menu_item if @can_manage_links
      withdraw_menu_item if @can_withdraw
    end
  end

  def edit_menu_item
    modal_menu_button("Edit")
  end

  # Opens the unified modal in edit mode for a non-author who may manage links
  # but not edit content — the server disables the content fields, leaving the
  # "also applies to" picker active.
  def link_menu_item
    modal_menu_button("Link to another capability")
  end

  def modal_menu_button(label)
    button(
      type: "button",
      class: "block w-full text-left px-3 py-1.5 text-gray-700 dark:text-gray-200 " \
             "hover:bg-gray-100 dark:hover:bg-gray-700",
      role: "menuitem",
      data: {
        action: "click->dropdown#close evidence-modal#load click->modal#open",
        modal_target_id: "evidence-modal-overlay",
        evidence_modal_mode_param: "edit",
        evidence_modal_evidence_id_param: @item.id,
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
        class: "block w-full text-left px-3 py-1.5 text-gray-700 dark:text-gray-200 " \
               "hover:bg-gray-100 dark:hover:bg-gray-700",
        role: "menuitem",
        form: { data: { turbo_confirm: "Unlink this evidence from this capability?" } }
      ) { "Unlink from this capability" }
    else
      span(
        class: "block w-full text-left px-3 py-1.5 text-gray-400 dark:text-gray-600 cursor-not-allowed",
        role: "menuitem",
        aria: { disabled: "true" },
        title: "This is the only place this evidence is linked — withdraw it instead."
      ) { "Unlink from this capability" }
    end
  end

  def withdraw_menu_item
    button_to(
      assessment_evidence_path(@assessment_id, @item.id),
      method: :delete,
      class: "block w-full text-left px-3 py-1.5 text-red-700 dark:text-red-300 " \
             "hover:bg-red-50 dark:hover:bg-red-900/30",
      role: "menuitem",
      form: { data: { turbo_confirm: "Withdraw this evidence?" } }
    ) { "Withdraw" }
  end
end
