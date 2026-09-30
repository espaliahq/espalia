# frozen_string_literal: true

# Lists pending and resolved suggested edits for a framework.
#
# Groups suggestions by review tier (3 highest first), with filters for
# status and entity type. Each row shows the diff summary, author, age,
# and links into the detail view.
#
class Views::Frameworks::Suggestions::IndexView < Views::Base
  STATUSES = FrameworkState::SuggestedEdit::STATUSES

  STATUS_VARIANTS = {
    "pending" => :warning,
    "approved" => :success,
    "rejected" => :default,
    "withdrawn" => :default,
    "resolved" => :success
  }.freeze

  # Canonical badge wording for suggestion kinds. "Archive" (never "Delete")
  # per §11 — archiving is the single removal operation.
  KIND_BADGE_LABELS = {
    "edit" => "Edit", "create" => "New", "delete" => "Archive",
    "clarification" => "Clarify"
  }.freeze

  TIER_LABELS = {
    1 => "Tier 1 — Examples",
    2 => "Tier 2 — Descriptions",
    3 => "Tier 3 — Behavioural expectations"
  }.freeze

  # The one definition lives in Frameworks::EntityLabels — the same map backs
  # the aggregate's and the Operations' user-facing error messages.
  ENTITY_TYPE_LABELS = Frameworks::EntityLabels::LABELS

  # @param framework [FrameworkState::Framework]
  # @param suggestions [Array<FrameworkState::SuggestedEdit>]
  # @param filters [Hash{Symbol => String, nil}]
  # @param user [User, nil]
  # @param current_tenant [Tenant, nil]
  # @param tenants [Array<Tenant>]
  def initialize(framework:, suggestions:, filters:, user: nil, current_tenant: nil, tenants: [])
    @framework = framework
    @suggestions = suggestions
    @filters = filters
    @user = user
    @current_tenant = current_tenant
    @tenants = tenants
    @author_names = Views::Frameworks::Suggestions::AuthorNames.for(
      @suggestions.map(&:author_id)
    )
  end

  def view_template
    render Components::Kit::PageLayout.new(
      user: @user, current_tenant: @current_tenant, tenants: @tenants
    ) do
      div(class: "max-w-5xl mx-auto") do
        back_link
        header
        filters_bar
        suggestions_body
      end
    end
  end

  private

  def back_link
    a(
      href: framework_path(@framework.framework_id),
      class: "text-sm text-gray-600 dark:text-gray-300 hover:text-primary-ink"
    ) { plain "\u2190 Back to framework" }
  end

  def header
    div(class: "mt-4 mb-6") do
      div(class: "flex items-center gap-3") do
        h1(class: "text-2xl font-bold text-gray-900 dark:text-white") { "Suggested edits" }
        render Components::Kit::Badge.new(@framework.name, variant: :info)
      end
      p(class: "mt-1 text-sm text-gray-600 dark:text-gray-300") do
        "Review and apply inline suggestions from collaborators."
      end
    end
  end

  def filters_bar
    div(
      class: "mb-6 flex flex-wrap items-center gap-2 border-b border-gray-200 " \
             "dark:border-gray-700 pb-4"
    ) do
      span(class: "text-xs font-semibold text-gray-600 dark:text-gray-300 uppercase") { "Status" }
      status_filter_link("All", nil)
      STATUSES.each { |status| status_filter_link(status.humanize, status) }
    end
  end

  def status_filter_link(label, status)
    active = @filters[:status] == status
    classes = if active
      "inline-flex items-center rounded-full px-3 py-1 text-xs font-medium " \
        "bg-primary text-white"
    else
      "inline-flex items-center rounded-full px-3 py-1 text-xs font-medium " \
        "bg-gray-100 dark:bg-gray-800 text-gray-700 dark:text-gray-300 " \
        "hover:bg-gray-200 dark:hover:bg-gray-700"
    end

    a(
      href: framework_suggestions_path(@framework.framework_id, status: status),
      class: classes
    ) { label }
  end

  def suggestions_body
    if @suggestions.empty?
      empty_state
    else
      grouped = @suggestions.group_by { |s| review_tier(s) }
      [ 3, 2, 1 ].each do |tier|
        rows = grouped[tier]
        next unless rows&.any?
        tier_section(tier, rows)
      end
    end
  end

  def empty_state
    render Components::Kit::Card.new do |card|
      card.body do
        div(class: "py-8 text-center") do
          p(class: "text-sm text-gray-600 dark:text-gray-300") do
            "No suggestions match these filters."
          end
        end
      end
    end
  end

  def tier_section(tier, suggestions)
    div(class: "mb-8") do
      h2(class: "text-sm font-semibold uppercase text-gray-600 dark:text-gray-300 mb-3") do
        TIER_LABELS[tier]
      end
      div(class: "space-y-3") do
        suggestions.each { |s| suggestion_card(s) }
      end
    end
  end

  def suggestion_card(suggestion)
    a(
      href: framework_suggestion_path(@framework.framework_id, suggestion.suggestion_id),
      class: "block group"
    ) do
      render Components::Kit::Card.new do |card|
        card.body do
          div(class: "flex items-start justify-between gap-4") do
            div(class: "min-w-0 flex-1") do
              suggestion_meta_row(suggestion)
              suggestion_diff_preview(suggestion)
              suggestion_footer(suggestion)
            end
            div(class: "shrink-0") do
              render Components::Kit::Badge.new(
                suggestion.status.humanize,
                variant: STATUS_VARIANTS.fetch(suggestion.status, :default)
              )
            end
          end
        end
      end
    end
  end

  def suggestion_meta_row(suggestion)
    div(class: "flex items-center gap-2 mb-2") do
      render Components::Kit::Badge.new(entity_label(suggestion))
      render Components::Kit::Badge.new(kind_label(suggestion.kind), variant: kind_variant(suggestion.kind))
      if suggestion.kind == "edit" && suggestion.field.present?
        span(class: "text-xs text-gray-600 dark:text-gray-300") do
          "field: #{suggestion.field}"
        end
      end
    end
  end

  def suggestion_diff_preview(suggestion)
    preview = suggestion_preview_text(suggestion)

    div(class: "text-sm text-gray-700 dark:text-gray-300 line-clamp-2 " \
                "group-hover:text-primary-ink transition-colors") do
      plain preview
    end
  end

  CONTENT_KEYS = %w[description name title code].freeze

  # @param suggestion [FrameworkState::SuggestedEdit]
  # @return [String]
  def suggestion_preview_text(suggestion)
    case suggestion.kind
    when "create"
      creation_preview(suggestion.proposed_attributes || {})
    when "delete"
      suggestion.current_value.to_s
    when "clarification"
      # A clarification proposes nothing — the question is its content.
      suggestion.rationale.to_s
    else
      suggestion.suggested_value.to_s
    end
  end

  # Prefers human-readable content keys over IDs when previewing a create.
  #
  # @param attrs [Hash]
  # @return [String]
  def creation_preview(attrs)
    normalized = attrs.transform_keys(&:to_s)
    CONTENT_KEYS.each do |key|
      value = normalized[key]
      return value.to_s if value.present?
    end
    normalized.values.select(&:present?).first.to_s
  end

  # @param kind [String] "edit", "create", or "delete"
  # @return [Symbol]
  def kind_variant(kind)
    case kind
    when "create" then :success
    when "delete" then :warning
    else :info
    end
  end

  # User-facing label for a suggestion kind. A delete-kind suggestion proposes
  # archiving the entity (the canonical operation), so it reads "archive".
  #
  # @param kind [String] "edit", "create", or "delete"
  # @return [String]
  def kind_label(kind)
    kind == "delete" ? "archive" : kind
  end

  def suggestion_footer(suggestion)
    div(class: "mt-2 flex items-center gap-3 text-xs text-gray-600 dark:text-gray-300") do
      span { "by #{@author_names.resolve(suggestion.author_id)}" }
      span { local_time_ago(suggestion.created_at) }
      if suggestion.rationale.present?
        span { "\u2014 #{truncate_text(suggestion.rationale, 80)}" }
      end
    end
  end

  def entity_label(suggestion)
    ENTITY_TYPE_LABELS.fetch(suggestion.target_entity_type, suggestion.target_entity_type.humanize)
  end

  def review_tier(suggestion)
    case suggestion.target_entity_type
    when "role_illustration" then 1
    when "behavioural_expectation" then 3
    else 2
    end
  end

  def local_time_ago(time)
    return "" unless time
    "#{time_ago_in_words_short(time)} ago"
  end

  def time_ago_in_words_short(time)
    seconds = (Time.current - time).to_i
    case seconds
    when 0..59 then "#{seconds}s"
    when 60..3599 then "#{seconds / 60}m"
    when 3600..86_399 then "#{seconds / 3600}h"
    else "#{seconds / 86_400}d"
    end
  end

  def truncate_text(text, length)
    return text if text.length <= length
    "#{text[0, length]}\u2026"
  end
end
