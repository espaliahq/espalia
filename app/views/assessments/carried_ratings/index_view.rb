# frozen_string_literal: true

# One category's ratings carried from the last cycle, each ticked by default,
# with the expectation it is rated against and the feedback recorded this
# cycle beside it — so a confirm is an informed one rather than a rubber
# stamp (#480). Posts the ticked cells to {Assessments::CarriedRatingsController#create}.
class Views::Assessments::CarriedRatings::IndexView < Views::Base
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
    render Components::Kit::PageLayout.new(user: @user, current_tenant: @current_tenant, tenants: @tenants) do
      div(class: "max-w-3xl") do
        header
        rows.empty? ? empty_state : confirm_form
      end
    end
  end

  private

  def header
    a(href: back_path, class: "text-sm text-gray-600 dark:text-gray-300 hover:underline") { "← Back to the assessment" }
    h1(class: "mt-2 text-2xl font-bold text-gray-900 dark:text-white") do
      "Confirm carried ratings · #{@category[:category].name}"
    end
    p(class: "mt-1 text-sm text-gray-600 dark:text-gray-300") do
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
        ul(class: "divide-y divide-gray-200 dark:divide-gray-800 rounded-lg border border-gray-200 " \
                  "dark:border-gray-800 bg-white dark:bg-gray-900") do
          rows.each { |row| row_item(row) }
        end
      end
      div(class: "mt-4 flex flex-wrap items-center gap-3") do
        button(type: "submit",
               class: "inline-flex min-h-11 items-center rounded-md bg-gray-900 dark:bg-white px-4 text-sm " \
                      "font-semibold text-white dark:text-gray-900 hover:bg-gray-800 dark:hover:bg-gray-100",
               data: { turbo_submits_with: "Confirming…" }) { "Confirm ticked ratings" }
        a(href: back_path, class: "text-sm text-gray-600 dark:text-gray-300 hover:underline") { "Cancel" }
      end
    end
  end

  def row_item(row)
    id = "carried-#{row[:stable_id]}-#{row[:ordinal]}"
    li(class: "flex gap-3 p-4") do
      input(type: "checkbox", id: id, name: "cells[]", value: "#{row[:stable_id]}|#{row[:ordinal]}", checked: true,
            class: "mt-1 h-5 w-5 shrink-0 rounded border-gray-300 dark:border-gray-600",
            aria: { describedby: "#{id}-detail" })
      div(class: "min-w-0 flex-1") do
        label(for: id, class: "flex flex-wrap items-baseline gap-x-2 text-sm font-semibold text-gray-900 dark:text-white") do
          span { row[:name] }
          span(class: "text-xs font-normal text-gray-600 dark:text-gray-300") { row[:level_code] }
          span(class: "text-xs font-medium text-gray-900 dark:text-white") { "· #{row[:phrase]}" }
        end
        div(id: "#{id}-detail", class: "mt-1 space-y-1 text-xs text-gray-600 dark:text-gray-300") do
          p { row[:expectation] } if row[:expectation].present?
          p(class: row[:new_feedback].positive? ? "font-medium text-gray-900 dark:text-white" : nil) do
            row[:new_feedback].positive? ? "#{row[:new_feedback]} new feedback this cycle" : "No new feedback this cycle"
          end
          a(href: assessment_path(@assignment, capability: row[:stable_id], level_ordinal: row[:ordinal]),
            class: "inline-block underline") { "Change it on the assessment" }
        end
      end
    end
  end

  def empty_state
    p(class: "mt-6 rounded-lg border border-dashed border-gray-300 dark:border-gray-700 p-6 text-sm " \
             "text-gray-600 dark:text-gray-300") { "Nothing in this category is waiting to be confirmed." }
  end

  # Every cell in the category still asking to be confirmed on the viewer's
  # side, by capability then level.
  def rows
    @rows ||= @category[:capabilities].flat_map do |cap_data|
      cap_data[:cells].sort.filter_map do |ordinal, cell|
        next unless Views::Assessments::Concerns::RatedCount.to_confirm?(cell, @context)

        frequency = cell[@context == :manager ? :manager_frequency : :current_frequency]
        config = Views::Assessments::FrequencyPalette.config_for(frequency)
        {
          stable_id: cap_data[:capability].stable_id, ordinal: ordinal, name: cap_data[:capability].name,
          level_code: level_code(ordinal), phrase: config&.dig(:phrase),
          expectation: cell[:expectation]&.description,
          new_feedback: Array(cell[:evidence]).count { |item| @cycle_id && item.cycle_id == @cycle_id }
        }
      end
    end
  end

  def level_code(ordinal)
    @merged_levels.find { |level| level[:ordinal] == ordinal }&.dig(:level_code) || "L#{ordinal}"
  end

  def subject_phrase
    count = rows.size
    whose = @assessee_name ? "#{@assessee_name.split.first}'s" : "Your"
    "#{whose} #{count} #{'rating'.pluralize(count)} here #{count == 1 ? 'was' : 'were'}"
  end

  def back_path
    assessment_path(@assignment, category: @category[:category].category_id)
  end
end
