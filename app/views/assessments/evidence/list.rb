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
      class: "mt-4 pt-3 border-t border-gray-200 dark:border-gray-700"
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

  # Header pairs the section label with a `+` affordance that opens the
  # evidence form. When the viewer can create, the whole header line is
  # the click target — a 1px-tall row of microtype was a hard-to-hit
  # affordance on touch.
  def header
    if @can_create
      add_button
    else
      div(class: header_label_classes) do
        header_label_content
      end
    end
  end

  def add_button
    button(
      type: "button",
      class: "#{header_label_classes} w-full text-left cursor-pointer rounded px-1 -mx-1 py-1 " \
             "hover:bg-gray-100 hover:text-gray-700 dark:hover:bg-gray-700/60 " \
             "dark:hover:text-gray-200 transition-colors",
      aria: { label: "Add evidence" },
      data: {
        action: "click->evidence-form#open",
        evidence_form_capability_stable_id_param: @capability_stable_id,
        evidence_form_level_ordinal_param: @level_ordinal
      }
    ) do
      header_label_content
      span(class: "ml-auto block text-sm leading-none", aria_hidden: "true") { "+" }
    end
  end

  def header_label_classes
    "flex items-center gap-1 text-[10px] uppercase tracking-wide " \
      "text-gray-500 dark:text-gray-400 mb-2"
  end

  # When the list is empty AND the viewer can create, lean the label
  # into the affordance ("Add evidence") rather than describing an
  # empty section ("Evidence"). When items exist, switch back to the
  # section label with a count so the row keeps its categorical meaning.
  def header_label_content
    if @items.any?
      span { "Evidence" }
      span(class: "font-mono") { "(#{@items.size})" }
    else
      span { "Add evidence" }
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
