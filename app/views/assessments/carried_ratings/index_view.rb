# frozen_string_literal: true

# One category's ratings carried from the last cycle, each ticked by default,
# with the expectation it is rated against and the feedback recorded this
# cycle beside it — so a confirm is an informed one rather than a rubber
# stamp (#480). Posts the ticked cells to {Assessments::CarriedRatingsController#create}.
class Views::Assessments::CarriedRatings::IndexView < Views::Base
  NEW_FEEDBACK_SHOWN = 3

  # @param assignment [PersonFrameworkAssignment]
  # @param category [Hash] one entry of `MatrixDataBuilder#build[:categories]`
  # @param context [Symbol] :self or :manager
  # @param merged_levels [Array<Hash>]
  # @param person_level [Integer]
  # @param cycle_id [String, nil] the open cycle, to tell this cycle's feedback apart
  # @param assessee_name [String, nil] nil when the viewer is the assessee
  def initialize(assignment:, category:, context:, merged_levels:, person_level:, cycle_id:, assessee_name:,
                 user:, current_tenant:, tenants:)
    @assignment = assignment
    @category = category
    @context = context
    @merged_levels = merged_levels
    @person_level = person_level
    @cycle_id = cycle_id
    @assessee_name = assessee_name
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Shell::PageLayout.new(user: @user, current_tenant: @current_tenant, tenants: @tenants) do
      div(class: "max-w-3xl") do
        header
        rows.empty? ? empty_state : confirm_form
      end
    end
  end

  private

  def header
    a(href: back_path, class: "text-sm text-muted hover:underline") { "← Back to the assessment" }
    h1(class: "mt-2 text-2xl font-bold text-default") do
      "Confirm carried ratings · #{@category[:category].name}"
    end
    p(class: "mt-1 text-sm text-muted") do
      plain "#{subject_phrase} carried from the last cycle. Untick any you want to rethink, "
      plain "then confirm the rest for this cycle. To change one, open it on the assessment instead."
    end
  end

  def confirm_form
    form(action: assessment_carried_ratings_path(@assignment), method: "post", class: "mt-6",
         data: { turbo_frame: "_top" }) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "category_id", value: @category[:category].category_id)
      fieldset do
        legend(class: "sr-only") { "Ratings to confirm" }
        render Components::Kit::Card.new(variant: :flush) do |card|
          card.body do
            ul(class: "divide-y divide-default") { rows.each { |row| row_item(row) } }
          end
        end
      end
      div(class: "mt-4 flex flex-wrap items-center gap-3") do
        render Components::Kit::Button.new(touch: true, type: :submit,
                                           data: { turbo_submits_with: "Confirming…" }) { "Confirm ticked ratings" }
        a(href: back_path, class: "text-sm text-muted hover:underline") { "Cancel" }
      end
    end
  end

  def row_item(row)
    id = "carried-#{row[:stable_id]}-#{row[:ordinal]}"
    li(class: "flex gap-3 p-4") do
      input(type: "checkbox", id: id, name: "cells[]", value: "#{row[:stable_id]}|#{row[:ordinal]}", checked: true,
            class: "mt-1 shrink-0 #{Components::Kit::Field::CHECKBOX}",
            aria: { describedby: "#{id}-detail" })
      div(class: "min-w-0 flex-1") do
        label(for: id, class: "flex flex-wrap items-baseline gap-x-2 text-sm font-semibold text-default") do
          span { row[:name] }
          span(class: "text-xs font-normal text-muted") { row[:level_code] }
          span(class: "text-xs font-medium text-default") { "· #{row[:phrase]}" }
        end
        div(id: "#{id}-detail", class: "mt-1 space-y-1 text-xs text-muted") do
          p { row[:expectation] } if row[:expectation].present?
          new_feedback(row[:new_feedback])
          a(href: assessment_path(@assignment, capability: row[:stable_id], level_ordinal: row[:ordinal]),
            class: "inline-block underline") { "Change it on the assessment" }
        end
      end
    end
  end

  # This cycle's feedback on the cell, read where the decision is made — a
  # count alone gave nothing to weigh before confirming.
  def new_feedback(items)
    if items.empty?
      p { "No new feedback this cycle" }
      return
    end

    p(class: "font-medium text-default") { "#{items.size} new feedback this cycle" }
    ul(class: "space-y-1 border-l-2 border-default pl-2") do
      items.first(NEW_FEEDBACK_SHOWN).each do |item|
        li do
          span(class: "font-medium") { item.title.presence || type_label(item) }
          plain " — #{Prose.to_plain(item.content).squish.truncate(160)}"
        end
      end
      li { "and #{items.size - NEW_FEEDBACK_SHOWN} more on the assessment" } if items.size > NEW_FEEDBACK_SHOWN
    end
  end

  # Same wording as the evidence card.
  def type_label(item)
    return item.custom_type_label.presence || "Other" if item.evidence_type == "other"

    Views::Assessments::Evidence::Card::TYPE_LABEL[item.evidence_type] || item.evidence_type.to_s.humanize
  end

  def empty_state
    div(class: "mt-6") do
      render Components::Kit::EmptyState.new(title: "Nothing in this category is waiting to be confirmed.", size: :panel)
    end
  end

  # The category's cells at the person's level still asking to be confirmed
  # on the viewer's side — the count the category link and status pill show.
  def rows
    @rows ||= Assessments::CarriedCell.at_level(@category[:capabilities], @person_level, @context).map do |cap_data|
      cell = cap_data[:cells][@person_level]
      frequency = cell[@context == :manager ? :manager_frequency : :current_frequency]
      {
        stable_id: cap_data[:capability].stable_id, ordinal: @person_level, name: cap_data[:capability].name,
        level_code: level_code(@person_level), phrase: Views::Assessments::FrequencyPalette.phrase_for(frequency),
        expectation: cell[:expectation]&.description,
        new_feedback: Array(cell[:evidence]).select { |item| @cycle_id && item.cycle_id == @cycle_id }
      }
    end
  end

  def level_code(ordinal)
    @merged_levels.find { |level| level[:ordinal] == ordinal }&.dig(:level_code) || "L#{ordinal}"
  end

  def subject_phrase
    count = rows.size
    whose = @assessee_name ? "#{Person.first_name(@assessee_name)}'s" : "Your"
    "#{whose} #{count} #{'rating'.pluralize(count)} here #{count == 1 ? 'was' : 'were'}"
  end

  def back_path
    assessment_path(@assignment, category: @category[:category].category_id)
  end
end
