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
      class: "mt-2 pt-2 border-t border-gray-200 dark:border-gray-700 group/evidence"
    ) do
      header
      ul(class: "space-y-0.5") do
        @items.each do |item|
          render Views::Assessments::Evidence::Card.new(
            item: item,
            assessment_id: @assessment_id,
            can_withdraw: can_withdraw?(item),
            can_relink: can_relink?(item)
          )
        end
      end
      add_button if @can_create
    end
  end

  private

  def dom_id
    "evidence-list-#{@capability_stable_id}-#{@level_ordinal}"
  end

  def header
    div(class: "flex items-center gap-1 text-[10px] uppercase tracking-wide " \
               "text-gray-500 dark:text-gray-400 mb-1") do
      span { "Evidence" }
      span(class: "font-mono") { "(#{@items.size})" } if @items.any?
    end
  end

  def add_button
    button(
      type: "button",
      class: "mt-1 w-full opacity-0 group-hover/evidence:opacity-100 focus:opacity-100 " \
             "transition-opacity text-[11px] text-primary border border-dashed " \
             "border-gray-300 dark:border-gray-600 rounded px-2 py-1 hover:bg-primary/5",
      data: {
        action: "click->evidence-form#open",
        evidence_form_capability_stable_id_param: @capability_stable_id,
        evidence_form_level_ordinal_param: @level_ordinal
      }
    ) do
      plain "+ Add evidence"
    end
  end

  def can_withdraw?(item)
    @viewer_person_id.present? && item.author_id == @viewer_person_id
  end

  def can_relink?(item)
    return false unless @viewer_person_id.present?

    item.author_id == @viewer_person_id || @can_relink_others
  end
end
