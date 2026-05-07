# frozen_string_literal: true

# Renders a single evidence item inside the expanded cell of an
# assessment matrix.
#
# Shows source dot (self/manager/peer), type label, optional title,
# content, optional external-link chip, author + relative timestamp.
# A hover-revealed action menu lets the author or anyone in the
# assessee's manager chain withdraw the item; relink lives behind the
# same menu.
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
    "other"             => nil
  }.freeze

  # @param item [EvidenceItem]
  # @param assessment_id [String] for routing the withdraw action
  # @param can_withdraw [Boolean] whether the current viewer may withdraw this item
  # @param can_relink [Boolean] whether the current viewer may relink this item
  def initialize(item:, assessment_id:, can_withdraw: false, can_relink: false)
    @item = item
    @assessment_id = assessment_id
    @can_withdraw = can_withdraw
    @can_relink = can_relink
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
        footer_line
      end
      actions_menu if @can_withdraw || @can_relink
    end
  end

  private

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

  def content_line
    p(class: "mt-0.5 text-gray-700 dark:text-gray-300 line-clamp-2") do
      @item.content
    end
  end

  def footer_line
    div(class: "mt-1 text-[10px] text-gray-400 dark:text-gray-500") do
      span { @item.author&.name || "Unknown" }
      plain " · "
      span { @item.recorded_at ? "#{time_ago_in_words(@item.recorded_at)} ago" : "—" }
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
    if ref.url.present?
      a(href: ref.url, target: "_blank", rel: "noopener noreferrer",
        class: "inline-flex items-center gap-0.5 rounded bg-gray-100 dark:bg-gray-700 " \
               "px-1.5 py-0.5 text-[10px] text-gray-600 dark:text-gray-300 hover:bg-gray-200 " \
               "dark:hover:bg-gray-600 hover:underline") { label }
    else
      span(class: "inline-flex items-center gap-0.5 rounded bg-gray-100 dark:bg-gray-700 " \
                 "px-1.5 py-0.5 text-[10px] text-gray-600 dark:text-gray-300") { label }
    end
  end

  # Hover-revealed kebab menu that hosts both Relink and Withdraw, plus
  # any future actions (copy link, edit). Uses the shared `dropdown`
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
      data: { dropdown_target: "trigger", action: "click->dropdown#toggle" },
      aria: { label: "Evidence actions", haspopup: "menu", expanded: "false" }
    ) do
      # Vertical 3-dot kebab — kept inline so we don't depend on an icon set.
      span(class: "block leading-none -mt-1 text-base", aria_hidden: "true") { "⋮" }
    end
  end

  def kebab_menu
    div(
      class: "hidden absolute right-0 mt-1 w-36 rounded-md border border-gray-200 " \
             "dark:border-gray-700 bg-white dark:bg-gray-900 shadow-lg z-10 " \
             "py-1 text-xs",
      role: "menu",
      data: { dropdown_target: "menu" }
    ) do
      relink_menu_item if @can_relink
      withdraw_menu_item if @can_withdraw
    end
  end

  def relink_menu_item
    button(
      type: "button",
      class: "block w-full text-left px-3 py-1.5 text-gray-700 dark:text-gray-200 " \
             "hover:bg-gray-100 dark:hover:bg-gray-700",
      role: "menuitem",
      data: {
        action: "click->dropdown#close click->evidence-relink-form#open",
        evidence_relink_form_evidence_id_param: @item.id,
        evidence_relink_form_capability_stable_id_param: @item.capability_stable_id,
        evidence_relink_form_level_ordinal_param: @item.level_ordinal
      }
    ) { "Relink" }
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
