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
    "withdrawn" => :default,
    "resolved" => :success
  }.freeze

  ENTITY_TYPE_LABELS = Views::Frameworks::Suggestions::IndexView::ENTITY_TYPE_LABELS

  # @param framework [FrameworkState::Framework]
  # @param suggestion [FrameworkState::SuggestedEdit]
  # @param can_approve [Boolean]
  # @param can_amend [Boolean]
  # @param can_withdraw [Boolean]
  # @param can_resolve [Boolean] clarification kinds only — resolve-with-note
  # @param user [User, nil]
  # @param current_tenant [Tenant, nil]
  # @param tenants [Array<Tenant>]
  def initialize(framework:, suggestion:, can_approve:, can_amend:, can_withdraw:,
                 can_resolve: false,
                 comments: [], viewer_person_id: nil, can_comment: false, tenant_admin: false,
                 user: nil, current_tenant: nil, tenants: [])
    @framework = framework
    @suggestion = suggestion
    @can_approve = can_approve
    @can_amend = can_amend
    @can_withdraw = can_withdraw
    @can_resolve = can_resolve
    @comments = comments
    @viewer_person_id = viewer_person_id
    @can_comment = can_comment
    @tenant_admin = tenant_admin
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
    @author_names = Views::Frameworks::Suggestions::AuthorNames.for(
      [ @suggestion.author_id, @suggestion.reviewed_by ]
    )
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
        discussion_card
      end
    end
  end

  private

  def back_link
    a(
      href: framework_suggestions_path(@framework.framework_id),
      class: "text-sm text-gray-600 dark:text-gray-300 hover:text-primary"
    ) { plain "\u2190 Back to suggestions" }
  end

  def header
    div(class: "mt-4 mb-6 flex items-start justify-between gap-4") do
      div do
        div(class: "flex items-center gap-3 mb-2") do
          h1(class: "text-2xl font-bold text-gray-900 dark:text-white") { header_title }
          render Components::Kit::Badge.new(
            @suggestion.status.humanize,
            variant: STATUS_VARIANTS.fetch(@suggestion.status, :default)
          )
        end
        p(class: "text-sm text-gray-600 dark:text-gray-300") do
          plain entity_label
          if @suggestion.kind == "edit"
            plain " \u00b7 field: "
            span(class: "font-mono text-xs") { @suggestion.field }
          end
        end
      end
    end
  end

  def header_title
    case @suggestion.kind
    when "create" then "Suggested creation"
    when "delete" then "Suggested archive"
    when "clarification" then "Clarification requested"
    else "Suggested edit"
    end
  end

  def diff_card
    case @suggestion.kind
    when "create" then create_diff_card
    when "delete" then delete_diff_card
    when "clarification" then clarification_card
    else edit_diff_card
    end
  end

  # A clarification proposes nothing — show the text under question (plain,
  # never struck) with its level; the question itself renders in the
  # rationale card below.
  def clarification_card
    render Components::Kit::Card.new(title: "Text under question") do |card|
      card.body do
        if clarification_level.present?
          p(class: "text-xs font-semibold uppercase text-gray-600 dark:text-gray-300 mb-1") do
            "#{entity_label} · L#{clarification_level}"
          end
        end
        p(class: "rounded-md border border-gray-200 dark:border-gray-700 " \
                 "bg-gray-50 dark:bg-gray-800/50 p-3 text-sm text-gray-900 dark:text-gray-100 " \
                 "whitespace-pre-wrap") do
          @suggestion.current_value.presence || "(no expectation defined at this level yet)"
        end
      end
    end
  end

  # The level the clarification concerns: a capability anchor carries it in
  # proposed_attributes; an expectation anchor implies it — resolve from the
  # expectation so the card can always name the cell.
  #
  # @return [Integer, String, nil]
  def clarification_level
    (@suggestion.proposed_attributes || {})["level_ordinal"] ||
      (@suggestion.target_entity_type == "behavioural_expectation" &&
        FrameworkState::BehaviouralExpectation
          .find_by(expectation_id: @suggestion.target_entity_id)&.level_ordinal)
  end

  def edit_diff_card
    render Components::Kit::Card.new(title: "Proposed change") do |card|
      card.body do
        div(class: "grid grid-cols-1 md:grid-cols-2 gap-4") do
          diff_column("Current", @suggestion.current_value, color: :red)
          diff_column("Proposed", @suggestion.suggested_value, color: :green)
        end
      end
    end
  end

  # Keys in proposed_attributes that are internal bookkeeping and add noise
  # to the human-facing diff card.
  HIDDEN_CREATE_ATTR_KEYS = %w[ordinal].freeze

  def create_diff_card
    attrs = (@suggestion.proposed_attributes || {}).transform_keys(&:to_s)

    render Components::Kit::Card.new(title: "Proposed new #{entity_label.downcase}") do |card|
      card.body do
        dl(class: "space-y-3") do
          parent_context_row if parent_context_label.present?

          attrs.each do |key, value|
            next if value.blank?
            next if HIDDEN_CREATE_ATTR_KEYS.include?(key)

            create_attr_row(key, value)
          end
        end
      end
    end
  end

  def create_attr_row(key, value)
    div do
      dt(class: "text-xs font-semibold uppercase text-gray-600 dark:text-gray-300") do
        key.humanize
      end
      dd(class: "mt-0.5 rounded-md border border-green-200 dark:border-green-900/50 " \
                "bg-green-50 dark:bg-green-950/30 p-3 text-sm text-gray-900 dark:text-gray-100") do
        plain resolve_attr_value(key, value)
      end
    end
  end

  def parent_context_row
    div do
      dt(class: "text-xs font-semibold uppercase text-gray-600 dark:text-gray-300") { "For" }
      dd(class: "mt-0.5 rounded-md border border-gray-200 dark:border-gray-700 " \
                "bg-gray-50 dark:bg-gray-800/50 p-3 text-sm text-gray-900 dark:text-gray-100") do
        plain parent_context_label
      end
    end
  end

  # Resolves FK-style UUID values to human-readable names. Falls back to the
  # raw value if the entity can't be found (e.g. deleted since the suggestion
  # was made).
  #
  # @param key [String]
  # @param value [Object]
  # @return [String]
  def resolve_attr_value(key, value)
    case key
    when "role_id"
      role = FrameworkState::Role.find_by(role_id: value)
      role ? "#{role.name} (#{role.code})" : value.to_s
    when "level_ordinal"
      "L#{value}"
    else
      value.to_s
    end
  end

  # Human-readable label for the parent entity this suggestion attaches to
  # (e.g. "Strategic Thinking · L3" for an illustration under an expectation).
  #
  # @return [String, nil]
  def parent_context_label
    return @parent_context_label if defined?(@parent_context_label)

    @parent_context_label =
      case @suggestion.target_entity_type
      when "role_illustration" then illustration_parent_label
      when "behavioural_expectation" then expectation_parent_label
      end
  end

  def illustration_parent_label
    expectation = FrameworkState::BehaviouralExpectation.find_by(expectation_id: @suggestion.parent_id)
    return nil unless expectation

    capability = FrameworkState::Capability.find_by(capability_id: expectation.capability_id)
    label = capability&.name.presence || "Expectation"
    "#{label} · L#{expectation.level_ordinal}"
  end

  def expectation_parent_label
    capability = FrameworkState::Capability.find_by(capability_id: @suggestion.parent_id)
    capability&.name
  end

  def delete_diff_card
    render Components::Kit::Card.new(title: "Proposed archive") do |card|
      card.body do
        diff_column("Will be removed", @suggestion.current_value, color: :red)
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
      h3(class: "text-xs font-semibold uppercase text-gray-600 dark:text-gray-300 mb-1") { label }
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
      title = @suggestion.kind == "clarification" ? "The question" : "Rationale"
      render Components::Kit::Card.new(title: title) do |card|
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
              dt(class: "text-gray-600 dark:text-gray-300") { "Reviewer" }
              dd(class: "mt-0.5 font-medium text-gray-900 dark:text-white") do
                plain @author_names.resolve(@suggestion.reviewed_by)
              end
            end
            div do
              dt(class: "text-gray-600 dark:text-gray-300") { "Reviewed at" }
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
                dt(class: "text-gray-600 dark:text-gray-300") do
                  @suggestion.status == "resolved" ? "Resolution" : "Comment"
                end
                dd(class: "mt-0.5 text-gray-900 dark:text-white whitespace-pre-wrap") do
                  @suggestion.reviewer_comment
                end
              end
            end
            if @suggestion.resulting_suggestion_id.present?
              div(class: "sm:col-span-2") do
                dt(class: "text-gray-600 dark:text-gray-300") { "Resulting change" }
                dd(class: "mt-0.5") do
                  a(
                    href: framework_suggestion_path(@framework.framework_id, @suggestion.resulting_suggestion_id),
                    class: "text-primary hover:underline text-sm"
                  ) { "View the resulting suggestion →" }
                end
              end
            end
          end
        end
      end
    end
  end

  # The discussion thread — the same component the context pane's suggestion
  # card renders, so the two surfaces can't drift. Threads stay open after
  # resolution.
  def discussion_card
    div(class: "mt-6") do
      render Components::Kit::Card.new(title: "Discussion") do |card|
        card.body do
          render Views::Frameworks::Suggestions::Thread.new(
            comments: @comments,
            framework_id: @framework.framework_id,
            suggestion_id: @suggestion.suggestion_id,
            viewer_person_id: @viewer_person_id,
            can_comment: @can_comment,
            tenant_admin: @tenant_admin,
            return_to: "detail"
          )
        end
      end
    end
  end

  def actions_card
    div(class: "mt-6") do
      render Components::Kit::Card.new(title: "Actions") do |card|
        card.body do
          div(class: "space-y-4") do
            primary_actions_row if primary_actions_visible?
            amend_section if amend_visible?
          end
        end
      end
    end
  end

  # Offered for edit-kind AND create-kind suggestions: the aggregate folds
  # an amended value into the entity's content field at approval
  # (CREATE_CONTENT_FIELD) and the projection folds it into
  # proposed_attributes for display, so a create amended here behaves
  # exactly like the matrix ghost's pencil (which uses the same endpoint).
  def amend_visible?
    @can_amend && @suggestion.status == "pending" && @suggestion.kind != "delete"
  end

  def any_actions_visible?
    primary_actions_visible? || amend_visible?
  end

  def primary_actions_visible?
    pending = @suggestion.status == "pending"
    (pending && @can_approve) || (pending && @can_resolve) || @can_withdraw
  end

  def primary_actions_row
    div(class: "flex flex-wrap items-center gap-3") do
      approve_form if @can_approve && @suggestion.status == "pending"
      reject_form  if @can_approve && @suggestion.status == "pending"
      withdraw_form if @can_withdraw
    end
    resolve_section if @can_resolve && @suggestion.status == "pending"
  end

  # A clarification's terminal action — resolve with a required note (and no
  # approve/reject: nothing is proposed).
  def resolve_section
    form(
      action: resolve_framework_suggestion_path(@framework.framework_id, @suggestion.suggestion_id),
      method: "post",
      class: "space-y-3"
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      div do
        label(
          for: "clarification_note",
          class: "block text-xs font-semibold uppercase text-gray-600 dark:text-gray-300 mb-1"
        ) { "Resolution" }
        textarea(
          id: "clarification_note", name: "note", rows: "2", required: true,
          placeholder: "What settled the question?",
          class: "block w-full rounded-md border border-gray-300 dark:border-gray-600 " \
                 "bg-white dark:bg-gray-800 px-3 py-2 text-sm text-gray-900 dark:text-white " \
                 "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-primary"
        )
      end
      button(
        type: "submit",
        class: "inline-flex items-center rounded-md bg-primary px-3 py-2 " \
               "text-sm font-semibold text-white shadow-xs hover:bg-primary/80 transition-colors"
      ) { "Resolve clarification" }
    end
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

  def amend_section
    details(class: "border-t border-gray-200 dark:border-gray-700 pt-4 group") do
      summary(
        class: "cursor-pointer list-none flex flex-wrap items-center justify-between gap-2 " \
               "text-sm font-semibold text-gray-900 dark:text-white select-none"
      ) do
        span(class: "flex items-center gap-2") do
          chevron_icon
          plain "Amend this suggestion"
        end
        span(class: "text-xs font-normal text-gray-600 dark:text-gray-300") do
          "Revise your own pending suggestion."
        end
      end

      form(
        action: amend_framework_suggestion_path(@framework.framework_id, @suggestion.suggestion_id),
        method: "post",
        class: "mt-4 space-y-4"
      ) do
        input(type: "hidden", name: "_method", value: "patch")
        input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)

        amend_value_field
        amend_rationale_field

        div(class: "flex items-center gap-3") do
          button(
            type: "submit",
            class: "inline-flex items-center rounded-md bg-primary px-3 py-2 " \
                   "text-sm font-semibold text-white shadow-xs hover:bg-primary/90 transition-colors"
          ) { "Save amendment" }
          a(
            href: framework_suggestion_path(@framework.framework_id, @suggestion.suggestion_id),
            class: "text-sm text-gray-600 dark:text-gray-300 hover:text-gray-700 dark:hover:text-gray-300"
          ) { "Cancel" }
        end
      end
    end
  end

  def amend_value_field
    div do
      label(
        for: "suggestion_suggested_value",
        class: "block text-xs font-semibold uppercase text-gray-600 dark:text-gray-300 mb-1"
      ) { amend_value_label }
      textarea(
        id: "suggestion_suggested_value",
        name: "suggestion[suggested_value]",
        rows: "4",
        class: "block w-full rounded-md border border-gray-300 dark:border-gray-600 " \
               "bg-white dark:bg-gray-800 px-3 py-2 text-sm text-gray-900 dark:text-white " \
               "focus:outline-none focus:ring-2 focus:ring-primary focus:border-transparent"
      ) { amend_value_default }
    end
  end

  def amend_rationale_field
    div do
      label(
        for: "suggestion_rationale",
        class: "block text-xs font-semibold uppercase text-gray-600 dark:text-gray-300 mb-1"
      ) { "Rationale (optional)" }
      textarea(
        id: "suggestion_rationale",
        name: "suggestion[rationale]",
        rows: "2",
        placeholder: "Why this change?",
        class: "block w-full rounded-md border border-gray-300 dark:border-gray-600 " \
               "bg-white dark:bg-gray-800 px-3 py-2 text-sm text-gray-900 dark:text-white " \
               "focus:outline-none focus:ring-2 focus:ring-primary focus:border-transparent"
      ) { @suggestion.rationale.to_s }
    end
  end

  # @return [String] label describing what the amend textarea edits, per kind.
  def amend_value_label
    case @suggestion.kind
    when "create"
      field_name = primary_proposed_attribute_key
      field_name ? "Revised #{field_name.humanize.downcase}" : "Revised content"
    when "edit"
      label = @suggestion.field.present? ? @suggestion.field.humanize.downcase : "value"
      "Revised #{label}"
    else
      "Revised value"
    end
  end

  # @return [String] starting value for the amend textarea, per kind.
  def amend_value_default
    case @suggestion.kind
    when "create"
      primary_proposed_attribute_value.to_s
    else
      @suggestion.suggested_value.to_s
    end
  end

  # The "main" content key of a create-kind suggestion's proposed_attributes
  # (description / name / title / code), falling back to the first present
  # value so the textarea is never empty.
  #
  # @return [String, nil]
  def primary_proposed_attribute_key
    attrs = (@suggestion.proposed_attributes || {}).transform_keys(&:to_s)
    %w[description name title code].find { |k| attrs[k].present? } ||
      attrs.find { |_, v| v.present? }&.first
  end

  # @return [String, nil]
  def primary_proposed_attribute_value
    attrs = (@suggestion.proposed_attributes || {}).transform_keys(&:to_s)
    key = primary_proposed_attribute_key
    key && attrs[key]
  end

  def chevron_icon
    svg(
      class: "w-4 h-4 text-gray-400 transition-transform group-open:rotate-90",
      fill: "none", viewBox: "0 0 24 24", stroke: "currentColor", stroke_width: "2"
    ) do |s|
      s.path(stroke_linecap: "round", stroke_linejoin: "round", d: "M9 5l7 7-7 7")
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
        class: "text-sm text-gray-500 hover:text-red-700 transition-colors"
      ) { "Withdraw" }
    end
  end

  def entity_label
    ENTITY_TYPE_LABELS.fetch(@suggestion.target_entity_type, @suggestion.target_entity_type.humanize)
  end
end
