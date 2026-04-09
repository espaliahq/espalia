# frozen_string_literal: true

# Detail page for a single framework suggested edit.
#
# Shows a side-by-side diff of current vs. proposed value, the author and
# rationale, and approve / reject / amend / withdraw actions gated by the
# permission flags resolved upstream by the controller.
#
class Views::Frameworks::Suggestions::ShowView < Views::Base
  STATUS_VARIANTS = {
    "pending" => :warning,
    "approved" => :success,
    "rejected" => :default,
    "withdrawn" => :default
  }.freeze

  ENTITY_TYPE_LABELS = Views::Frameworks::Suggestions::IndexView::ENTITY_TYPE_LABELS

  # @param framework [FrameworkState::Framework]
  # @param suggestion [FrameworkState::SuggestedEdit]
  # @param can_approve [Boolean]
  # @param can_amend [Boolean]
  # @param can_withdraw [Boolean]
  # @param user [User, nil]
  # @param current_tenant [Tenant, nil]
  # @param tenants [Array<Tenant>]
  def initialize(framework:, suggestion:, can_approve:, can_amend:, can_withdraw:,
                 user: nil, current_tenant: nil, tenants: [])
    @framework = framework
    @suggestion = suggestion
    @can_approve = can_approve
    @can_amend = can_amend
    @can_withdraw = can_withdraw
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
  end

  def view_template
    render Components::Kit::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(class: "max-w-4xl mx-auto") do
        back_link
        header
        diff_card
        rationale_card if @suggestion.rationale.present?
        review_history_card unless @suggestion.status == "pending"
        actions_card if any_actions_visible?
      end
    end
  end

  private

  def back_link
    a(
      href: framework_suggestions_path(@framework.framework_id),
      class: "text-sm text-gray-500 dark:text-gray-400 hover:text-primary"
    ) { plain "\u2190 Back to suggestions" }
  end

  def header
    div(class: "mt-4 mb-6 flex items-start justify-between gap-4") do
      div do
        div(class: "flex items-center gap-3 mb-2") do
          h1(class: "text-2xl font-bold text-gray-900 dark:text-white") { "Suggested edit" }
          render Components::Kit::Badge.new(
            @suggestion.status.humanize,
            variant: STATUS_VARIANTS.fetch(@suggestion.status, :default)
          )
        end
        p(class: "text-sm text-gray-500 dark:text-gray-400") do
          plain "#{entity_label} \u00b7 field: "
          span(class: "font-mono text-xs") { @suggestion.field }
        end
      end
    end
  end

  def diff_card
    render Components::Kit::Card.new(title: "Proposed change") do |card|
      card.body do
        div(class: "grid grid-cols-1 md:grid-cols-2 gap-4") do
          diff_column("Current", @suggestion.current_value, color: :red)
          diff_column("Proposed", @suggestion.suggested_value, color: :green)
        end
      end
    end
  end

  def diff_column(label, value, color:)
    classes = case color
    when :red
      "border-red-200 dark:border-red-900/50 bg-red-50 dark:bg-red-950/30"
    when :green
      "border-green-200 dark:border-green-900/50 bg-green-50 dark:bg-green-950/30"
    end

    div do
      h3(class: "text-xs font-semibold uppercase text-gray-500 dark:text-gray-400 mb-1") { label }
      pre(
        class: "rounded-md border #{classes} p-3 text-sm text-gray-900 dark:text-gray-100 " \
               "whitespace-pre-wrap font-sans"
      ) do
        plain value.presence || "(empty)"
      end
    end
  end

  def rationale_card
    div(class: "mt-6") do
      render Components::Kit::Card.new(title: "Rationale") do |card|
        card.body do
          p(class: "text-sm text-gray-700 dark:text-gray-300 whitespace-pre-wrap") do
            @suggestion.rationale
          end
        end
      end
    end
  end

  def review_history_card
    div(class: "mt-6") do
      render Components::Kit::Card.new(title: "Review") do |card|
        card.body do
          dl(class: "grid grid-cols-1 sm:grid-cols-2 gap-4 text-sm") do
            div do
              dt(class: "text-gray-500 dark:text-gray-400") { "Reviewer" }
              dd(class: "mt-0.5 font-medium text-gray-900 dark:text-white") do
                plain @suggestion.reviewed_by.to_s.first(8) + "\u2026"
              end
            end
            div do
              dt(class: "text-gray-500 dark:text-gray-400") { "Reviewed at" }
              dd(class: "mt-0.5 font-medium text-gray-900 dark:text-white") do
                if @suggestion.reviewed_at
                  local_time(@suggestion.reviewed_at)
                else
                  plain "\u2014"
                end
              end
            end
            if @suggestion.reviewer_comment.present?
              div(class: "sm:col-span-2") do
                dt(class: "text-gray-500 dark:text-gray-400") { "Comment" }
                dd(class: "mt-0.5 text-gray-900 dark:text-white whitespace-pre-wrap") do
                  @suggestion.reviewer_comment
                end
              end
            end
          end
        end
      end
    end
  end

  def actions_card
    div(class: "mt-6") do
      render Components::Kit::Card.new(title: "Actions") do |card|
        card.body do
          div(class: "flex flex-wrap items-center gap-3") do
            approve_form if @can_approve && @suggestion.status == "pending"
            reject_form  if @can_approve && @suggestion.status == "pending"
            amend_form   if @can_amend
            withdraw_form if @can_withdraw
          end
        end
      end
    end
  end

  def any_actions_visible?
    pending = @suggestion.status == "pending"
    (pending && @can_approve) || @can_amend || @can_withdraw
  end

  def approve_form
    form(
      action: approve_framework_suggestion_path(@framework.framework_id, @suggestion.suggestion_id),
      method: "post",
      class: "inline"
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      button(
        type: "submit",
        class: "inline-flex items-center rounded-md bg-green-600 px-3 py-2 " \
               "text-sm font-semibold text-white shadow-xs hover:bg-green-700 transition-colors"
      ) { "Approve" }
    end
  end

  def reject_form
    form(
      action: reject_framework_suggestion_path(@framework.framework_id, @suggestion.suggestion_id),
      method: "post",
      class: "inline",
      data: { turbo_confirm: "Reject this suggestion?" }
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      button(
        type: "submit",
        class: "inline-flex items-center rounded-md bg-red-600 px-3 py-2 " \
               "text-sm font-semibold text-white shadow-xs hover:bg-red-700 transition-colors"
      ) { "Reject" }
    end
  end

  def amend_form
    details(class: "inline-block") do
      summary(
        class: "cursor-pointer inline-flex items-center rounded-md " \
               "border border-gray-300 dark:border-gray-600 px-3 py-2 text-sm " \
               "font-semibold text-gray-700 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-800"
      ) { "Amend" }

      form(
        action: amend_framework_suggestion_path(@framework.framework_id, @suggestion.suggestion_id),
        method: "post",
        class: "mt-3 space-y-3 w-full"
      ) do
        input(type: "hidden", name: "_method", value: "patch")
        input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)

        div do
          label(
            for: "suggestion_suggested_value",
            class: "block text-xs font-medium text-gray-700 dark:text-gray-300 mb-1"
          ) { "Revised value" }
          textarea(
            id: "suggestion_suggested_value",
            name: "suggestion[suggested_value]",
            rows: "4",
            class: "block w-full rounded-md border border-gray-300 dark:border-gray-600 " \
                   "bg-white dark:bg-gray-800 px-3 py-2 text-sm text-gray-900 dark:text-white"
          ) { @suggestion.suggested_value.to_s }
        end

        div do
          label(
            for: "suggestion_rationale",
            class: "block text-xs font-medium text-gray-700 dark:text-gray-300 mb-1"
          ) { "Rationale (optional)" }
          textarea(
            id: "suggestion_rationale",
            name: "suggestion[rationale]",
            rows: "2",
            class: "block w-full rounded-md border border-gray-300 dark:border-gray-600 " \
                   "bg-white dark:bg-gray-800 px-3 py-2 text-sm text-gray-900 dark:text-white"
          ) { @suggestion.rationale.to_s }
        end

        button(
          type: "submit",
          class: "inline-flex items-center rounded-md bg-primary px-3 py-2 " \
                 "text-sm font-semibold text-white shadow-xs hover:bg-primary/90 transition-colors"
        ) { "Save amendment" }
      end
    end
  end

  def withdraw_form
    form(
      action: framework_suggestion_path(@framework.framework_id, @suggestion.suggestion_id),
      method: "post",
      class: "inline",
      data: { turbo_confirm: "Withdraw this suggestion?" }
    ) do
      input(type: "hidden", name: "_method", value: "delete")
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      button(
        type: "submit",
        class: "text-sm text-gray-500 hover:text-red-600 transition-colors"
      ) { "Withdraw" }
    end
  end

  def entity_label
    ENTITY_TYPE_LABELS.fetch(@suggestion.target_entity_type, @suggestion.target_entity_type.humanize)
  end
end
