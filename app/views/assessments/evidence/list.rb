# frozen_string_literal: true

# Stack of evidence cards inside the expanded cell, under a header carrying
# the Add and Request actions the viewer is permitted.
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
  # @param read_only [Boolean] a past cycle's page: no item can be edited,
  #   relinked or withdrawn from it
  def initialize(items:, assessment_id:, viewer_person_id:, can_create:,
                 capability_stable_id:, level_ordinal:, can_relink_others: false,
                 can_request: false, read_only: false)
    @read_only = read_only
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

  # Section label on the left; the cell actions as visible buttons on the
  # right, shown only for the actions the viewer is permitted. Not a kebab:
  # each card has one, and two stacked kebabs were mistaken for each other.
  def header
    div(class: "flex items-center justify-between mb-2") do
      div(class: header_label_classes) { header_label_content }
      actions if @can_create || @can_request
    end
  end

  def header_label_classes
    "flex items-center gap-1 text-[10px] uppercase tracking-wide text-muted"
  end

  def header_label_content
    span { "Feedback / Evidence" }
    span(class: "font-mono") { "(#{@items.size})" } if @items.any?
  end

  def actions
    div(class: "flex items-center gap-1") do
      add_button if @can_create
      request_button if @can_request
    end
  end

  # The ids let the modal return focus to the button's replacement when a
  # frame load or a saved cell re-renders the list.
  def add_button
    render Components::Kit::Button.new(
      variant: :ghost, size: :xs, id: "#{dom_id}-add",
      data: {
        action: "evidence-modal#load click->modal#open",
        modal_target_id: "evidence-modal-overlay",
        evidence_modal_mode_param: "new",
        evidence_modal_assignment_id_param: @assessment_id,
        evidence_modal_capability_stable_id_param: @capability_stable_id,
        evidence_modal_level_ordinal_param: @level_ordinal,
        evidence_modal_return_to_param: "assessment:#{@assessment_id}"
      }
    ) do
      icon("plus", class: "size-3")
      plain "Add"
      span(class: "sr-only") { " feedback / evidence" }
    end
  end

  def request_button
    render Components::Kit::Button.new(
      variant: :ghost, size: :xs, id: "#{dom_id}-request",
      data: {
        action: "request-evidence#load click->modal#open",
        modal_target_id: "evidence-request-modal-overlay",
        request_evidence_assignment_id_param: @assessment_id,
        request_evidence_capability_stable_id_param: @capability_stable_id,
        request_evidence_level_ordinal_param: @level_ordinal
      }
    ) do
      plain "Request"
      span(class: "sr-only") { " feedback / evidence" }
    end
  end

  def can_withdraw?(item)
    !@read_only && @viewer_person_id.present? && item.author_id == @viewer_person_id
  end

  # Author may manage their own evidence's links; the assessee and their
  # manager chain (`@can_relink_others`) may manage any item's links.
  def can_manage_links?(item)
    return false if @read_only || @viewer_person_id.blank?
    return false if item.withdrawn?

    item.author_id == @viewer_person_id || @can_relink_others
  end

  # Author-only edit (matches {EvidencePolicy#update?}); withdrawn items
  # are not editable.
  def can_update?(item)
    return false if @read_only || @viewer_person_id.blank?
    return false if item.withdrawn?

    item.author_id == @viewer_person_id
  end
end
