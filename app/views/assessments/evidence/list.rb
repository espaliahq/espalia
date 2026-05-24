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
  #   or anywhere in their manager hierarchy — these users may relink
  #   any evidence on this assessment, not just items they authored.
  # @param capability_stable_id [String]
  # @param level_ordinal [Integer]
  def initialize(items:, assessment_id:, viewer_person_id:, can_create:,
                 capability_stable_id:, level_ordinal:, can_relink_others: false)
    @items = items
    @assessment_id = assessment_id
    @viewer_person_id = viewer_person_id
    @can_create = can_create
    @can_relink_others = can_relink_others
    @capability_stable_id = capability_stable_id
    @level_ordinal = level_ordinal
  end

  def view_template
    div(
      id: dom_id,
      class: "mt-2 pt-2 border-t border-gray-200 dark:border-gray-700"
    ) do
      header
      ul(class: "space-y-0.5") do
        @items.each do |item|
          render Views::Assessments::Evidence::Card.new(
            item: item,
            assessment_id: @assessment_id,
            can_withdraw: can_withdraw?(item),
            can_relink: can_relink?(item),
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

  # Header pairs the section label with a small `+` affordance that
  # opens the evidence form. Replaces the previous full-width dashed
  # button — same target action, far less vertical space.
  def header
    div(class: "flex items-center gap-1 text-[10px] uppercase tracking-wide " \
               "text-gray-500 dark:text-gray-400 mb-1") do
      span { "Evidence" }
      span(class: "font-mono") { "(#{@items.size})" } if @items.any?
      add_icon if @can_create
    end
  end

  def add_icon
    button(
      type: "button",
      class: "ml-auto rounded p-0.5 text-gray-400 hover:text-gray-700 hover:bg-gray-100 " \
             "dark:hover:bg-gray-700 dark:hover:text-gray-200",
      aria: { label: "Add evidence" },
      data: {
        action: "click->evidence-form#open",
        evidence_form_capability_stable_id_param: @capability_stable_id,
        evidence_form_level_ordinal_param: @level_ordinal
      }
    ) do
      span(class: "block text-sm leading-none", aria_hidden: "true") { "+" }
    end
  end

  def can_withdraw?(item)
    @viewer_person_id.present? && item.author_id == @viewer_person_id
  end

  def can_relink?(item)
    return false unless @viewer_person_id.present?

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
