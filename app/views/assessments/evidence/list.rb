# frozen_string_literal: true

# Stack of evidence cards inside the expanded cell, plus a hover-revealed
# "+ Add evidence" affordance when the viewer has create permission.
#
class Views::Assessments::Evidence::List < Views::Base
  # @param items [Array<EvidenceItem>]
  # @param assessment_id [String]
  # @param viewer_person_id [String, nil]
  # @param can_create [Boolean]
  # @param can_relink_others [Boolean] true when the viewer is the assessee
  #   or anywhere in their manager hierarchy — these users may manage the
  #   links (add/remove capability × level) of ANY evidence on this
  #   assessment, not just items they authored.
  # @param capability_stable_id [String]
  # @param level_ordinal [Integer]
  def initialize(items:, assessment_id:, viewer_person_id:, can_create:,
                 capability_stable_id:, level_ordinal:, can_relink_others: false,
                 can_request: false)
    @items = items
    @assessment_id = assessment_id
    @viewer_person_id = viewer_person_id
    @can_create = can_create
    @can_request = can_request
    @can_relink_others = can_relink_others
    @capability_stable_id = capability_stable_id
    @level_ordinal = level_ordinal
  end

  def view_template
    div(
      id: dom_id,
      class: "mt-4 pt-3 border-t border-gray-200 dark:border-gray-700"
    ) do
      header
      ul(class: "space-y-0.5") do
        @items.each do |item|
          render Views::Assessments::Evidence::Card.new(
            item: item,
            assessment_id: @assessment_id,
            current_capability_stable_id: @capability_stable_id,
            current_level_ordinal: @level_ordinal,
            can_withdraw: can_withdraw?(item),
            can_manage_links: can_manage_links?(item),
            can_update: can_update?(item)
          )
        end
      end
    end
  end

  private

  def dom_id
    "evidence-list-#{@capability_stable_id}-#{@level_ordinal}"
  end

  # Section label on the left; a kebab (⋮) menu on the right gathering the cell
  # actions ("Add evidence" / "Request evidence"), shown only for the actions the
  # viewer is permitted. Read-only peers see the plain label.
  def header
    div(class: "flex items-center justify-between mb-2") do
      div(class: header_label_classes) { header_label_content }
      actions_menu if @can_create || @can_request
    end
  end

  def header_label_classes
    "flex items-center gap-1 text-[10px] uppercase tracking-wide text-gray-600 dark:text-gray-300"
  end

  def header_label_content
    span { "Evidence" }
    span(class: "font-mono") { "(#{@items.size})" } if @items.any?
  end

  def actions_menu
    div(class: "relative", data: { controller: "dropdown", action: "keydown.esc@window->dropdown#close" }) do
      button(
        type: "button",
        class: "rounded p-1 text-gray-400 hover:text-gray-700 hover:bg-gray-100 " \
               "dark:hover:bg-gray-700 dark:hover:text-gray-200",
        data: { dropdown_target: "trigger", action: "dropdown#toggle" },
        aria: { label: "Evidence actions", haspopup: "menu", expanded: "false" }
      ) { span(class: "block leading-none text-base", aria_hidden: "true") { "⋮" } }
      div(
        class: "hidden absolute right-0 mt-1 w-48 rounded-md border border-gray-200 dark:border-gray-700 " \
               "bg-white dark:bg-gray-900 shadow-lg z-10 py-1 text-xs",
        role: "menu", data: { dropdown_target: "menu" }
      ) do
        add_menu_item if @can_create
        request_menu_item if @can_request
      end
    end
  end

  def add_menu_item
    button(
      type: "button", class: menu_item_classes, role: "menuitem",
      data: {
        action: "click->dropdown#close evidence-modal#load click->modal#open",
        modal_target_id: "evidence-modal-overlay",
        evidence_modal_mode_param: "new",
        evidence_modal_assignment_id_param: @assessment_id,
        evidence_modal_capability_stable_id_param: @capability_stable_id,
        evidence_modal_level_ordinal_param: @level_ordinal,
        evidence_modal_return_to_param: "assessment:#{@assessment_id}"
      }
    ) { "Add evidence" }
  end

  def request_menu_item
    button(
      type: "button", class: menu_item_classes, role: "menuitem",
      data: {
        action: "click->dropdown#close request-evidence#load click->modal#open",
        modal_target_id: "evidence-request-modal-overlay",
        request_evidence_assignment_id_param: @assessment_id,
        request_evidence_capability_stable_id_param: @capability_stable_id,
        request_evidence_level_ordinal_param: @level_ordinal
      }
    ) { "Request evidence" }
  end

  def menu_item_classes
    "block w-full text-left px-3 py-1.5 text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-700"
  end

  def can_withdraw?(item)
    @viewer_person_id.present? && item.author_id == @viewer_person_id
  end

  # Author may manage their own evidence's links; the assessee and their
  # manager chain (`@can_relink_others`) may manage any item's links.
  def can_manage_links?(item)
    return false unless @viewer_person_id.present?
    return false if item.withdrawn?

    item.author_id == @viewer_person_id || @can_relink_others
  end

  # Author-only edit (matches {EvidencePolicy#update?}); withdrawn items
  # are not editable.
  def can_update?(item)
    return false unless @viewer_person_id.present?
    return false if item.withdrawn?

    item.author_id == @viewer_person_id
  end
end
