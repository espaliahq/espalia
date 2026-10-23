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
      class: "mt-4 pt-3 border-t border-default"
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
    "flex items-center gap-1 text-[10px] uppercase tracking-wide text-muted"
  end

  def header_label_content
    span { "Feedback / Evidence" }
    span(class: "font-mono") { "(#{@items.size})" } if @items.any?
  end

  def actions_menu
    render Components::Kit::Dropdown.new do |dropdown|
      dropdown.trigger(label: "Feedback / evidence actions", button: { variant: :ghost, size: :xs, icon: true }) do
        icon("kebab", class: "size-4")
      end
      dropdown.menu(width: "w-48") do
        add_menu_item(dropdown) if @can_create
        request_menu_item(dropdown) if @can_request
      end
    end
  end

  def add_menu_item(dropdown)
    dropdown.item(
      size: :xs,
      data: {
        action: "click->dropdown#close evidence-modal#load click->modal#open",
        modal_target_id: "evidence-modal-overlay",
        evidence_modal_mode_param: "new",
        evidence_modal_assignment_id_param: @assessment_id,
        evidence_modal_capability_stable_id_param: @capability_stable_id,
        evidence_modal_level_ordinal_param: @level_ordinal,
        evidence_modal_return_to_param: "assessment:#{@assessment_id}"
      }
    ) { "Add feedback / evidence" }
  end

  def request_menu_item(dropdown)
    dropdown.item(
      size: :xs,
      data: {
        action: "click->dropdown#close request-evidence#load click->modal#open",
        modal_target_id: "evidence-request-modal-overlay",
        request_evidence_assignment_id_param: @assessment_id,
        request_evidence_capability_stable_id_param: @capability_stable_id,
        request_evidence_level_ordinal_param: @level_ordinal
      }
    ) { "Request feedback / evidence" }
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
