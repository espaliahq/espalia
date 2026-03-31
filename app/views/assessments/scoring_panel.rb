# frozen_string_literal: true

# Scoring summary sidebar for the assessment view.
#
# Multi-perspective display: shows the primary perspective's score prominently
# with compact secondary bars for other perspectives (self, manager, agreed).
# Mirrors the visual language of AssessmentCell's FrequencyBar for consistency.
#
# Three-tier performance signal:
# 1. Below expectations (< meeting_expectation_threshold) — performance concern
# 2. Meeting expectations (≥ meeting_expectation_threshold, default 0.95) — at baseline
# 3. Mastering (≥ mastery_threshold) — significantly exceeding
#
# Wrapped in a targetable div for Turbo Frame replacement.
#
class Views::Assessments::ScoringPanel < Views::Base
  AMBER_THRESHOLD = 0.8

  CONTEXT_LABELS = {
    self: "Self Assessment",
    manager: "Manager Assessment",
    alignment: "Agreed Assessment"
  }.freeze

  # @param scoring [Hash] effective scoring from MatrixDataBuilder
  # @param self_scoring [Hash, nil] self-only perspective scoring
  # @param manager_scoring [Hash, nil] manager-only perspective scoring
  # @param aligned_scoring [Hash, nil] aligned-only perspective scoring
  # @param categories [Array<Hash>] category data from MatrixDataBuilder
  # @param person_level [Integer]
  # @param mastery_threshold [Float] ratio threshold for mastering tier
  # @param meeting_expectation_threshold [Float] ratio threshold for meeting tier
  # @param context [Symbol] :self, :manager, or :alignment
  def initialize(scoring:, categories:, person_level:,
                 self_scoring: nil, manager_scoring: nil, aligned_scoring: nil,
                 mastery_threshold: PersonDevelopment::Scoring::DEFAULT_MASTERY_THRESHOLD,
                 meeting_expectation_threshold: PersonDevelopment::Scoring::DEFAULT_MEETING_EXPECTATION_THRESHOLD,
                 context: :self)
    @scoring = scoring
    @self_scoring = self_scoring
    @manager_scoring = manager_scoring
    @aligned_scoring = aligned_scoring
    @categories = categories
    @person_level = person_level
    @mastery_threshold = mastery_threshold
    @meeting_expectation_threshold = meeting_expectation_threshold
    @context = context
  end

  def view_template
    ratio = primary_scoring[:performance_ratio] || 0.0
    div(id: "scoring-panel", class: "p-5 space-y-6",
        data: { performance_pct: (ratio * 100).round(0) }) do
      context_label
      performance_section
      status_tier_section
      category_results_section
      promotion_section
    end
  end

  private

  # ── Context label ──

  def context_label
    label = CONTEXT_LABELS[@context] || CONTEXT_LABELS[:self]
    div(class: "flex items-center gap-2") do
      span(class: "text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wide") do
        label
      end
    end
  end

  # ── Performance ──

  def performance_section
    ratio = primary_scoring[:performance_ratio] || 0.0
    pct = (ratio * 100).round(0)

    div do
      h3(class: "text-sm font-semibold text-gray-900 dark:text-white mb-2") { "Performance" }

      div(class: "flex items-baseline gap-2 mb-2") do
        span(class: "text-3xl font-bold #{performance_color(ratio)}") { "#{pct}%" }
        span(class: "text-xs text-gray-500 dark:text-gray-400") { "of expected" }
      end

      # Progress bar
      div(class: "w-full bg-gray-200 dark:bg-gray-700 rounded-full h-2") do
        width = [ pct, 150 ].min.to_f / 1.5  # scale so 150% fills the bar
        div(class: "#{performance_bar_color(ratio)} h-2 rounded-full transition-all duration-300",
            style: "width: #{[ width, 100 ].min.round(0)}%") { }
      end

      # Secondary perspective bars
      secondary_scorings.each do |label, scoring|
        secondary_performance_bar(label, scoring)
      end
    end
  end

  # Compact bar showing a secondary perspective's performance ratio.
  # Mirrors FrequencyBar visual pattern: label, colored strip, percentage.
  #
  # @param label [String] "Self", "Mgr", or "Agreed"
  # @param scoring [Hash] scoring output for the perspective
  def secondary_performance_bar(label, scoring)
    ratio = scoring[:performance_ratio] || 0.0
    pct = (ratio * 100).round(0)
    primary_ratio = primary_scoring[:performance_ratio] || 0.0
    diverges = (pct - (primary_ratio * 100).round(0)).abs >= 5

    div(class: "flex items-center gap-1.5 mt-1.5") do
      span(class: "text-[10px] text-gray-400 dark:text-gray-500 w-9 shrink-0") { "#{label}:" }

      div(class: "flex-1 h-1.5 rounded-full bg-gray-100 dark:bg-gray-800 overflow-hidden") do
        bar_width = [ pct, 150 ].min.to_f / 1.5
        div(class: "h-full rounded-full #{performance_bar_color(ratio)}",
            style: "width: #{[ bar_width, 100 ].min.round(0)}%") { }
      end

      span(class: "text-[10px] text-gray-500 dark:text-gray-400 w-7 shrink-0 text-right") do
        "#{pct}%"
      end

      if diverges
        span(
          class: "w-1.5 h-1.5 rounded-full bg-amber-400 dark:bg-amber-500 shrink-0",
          title: "Differs from #{CONTEXT_LABELS[@context]&.downcase}"
        ) { }
      else
        span(class: "w-1.5 shrink-0") { }
      end
    end
  end

  # ── Status tier ──

  def status_tier_section
    meeting = primary_scoring[:meeting_expectations]
    mastering = primary_scoring[:mastering]

    div(class: "space-y-2") do
      if mastering
        status_badge(
          "Mastering",
          "Significantly exceeding expectations",
          "bg-purple-50 dark:bg-purple-900/20 border-purple-200 dark:border-purple-800",
          "text-purple-800 dark:text-purple-300"
        )
      elsif meeting
        status_badge(
          "Meeting expectations",
          "Performing at or above current level baseline",
          "bg-green-50 dark:bg-green-900/20 border-green-200 dark:border-green-800",
          "text-green-800 dark:text-green-300"
        )
      else
        status_badge(
          "Below expectations",
          "Performance is below current level baseline",
          "bg-red-50 dark:bg-red-900/20 border-red-200 dark:border-red-800",
          "text-red-800 dark:text-red-300"
        )
        blocked_capabilities_detail
      end

      # Secondary tier annotations when other perspectives disagree
      secondary_tier_annotations
    end
  end

  # Shows divergent tier verdicts from secondary perspectives.
  #
  def secondary_tier_annotations
    primary_tier = tier_for(primary_scoring)

    secondary_scorings.each do |label, scoring|
      alt_tier = tier_for(scoring)
      next if alt_tier == primary_tier

      text, color =
        case alt_tier
        when :mastering
          [ "Mastering", "text-purple-600 dark:text-purple-400" ]
        when :meeting
          [ "Meeting expectations", "text-green-600 dark:text-green-400" ]
        else
          [ "Below expectations", "text-red-600 dark:text-red-400" ]
        end

      div(class: "flex items-center gap-1.5 px-3 py-1") do
        span(
          class: "w-1.5 h-1.5 rounded-full bg-amber-400 dark:bg-amber-500 shrink-0",
          title: "Divergent assessment"
        ) { }
        span(class: "text-xs text-gray-500 dark:text-gray-400") do
          "#{label}: "
        end
        span(class: "text-xs font-medium #{color}") { text }
      end
    end
  end

  def status_badge(title, description, container_classes, text_classes)
    div(class: "p-3 rounded-md border #{container_classes}") do
      span(class: "text-sm font-medium #{text_classes}") { title }
      p(class: "mt-0.5 text-xs #{text_classes} opacity-75") { description }
    end
  end

  # ── Categories ──

  def category_results_section
    results = primary_scoring[:category_results] || {}
    return if results.empty?

    div do
      h3(class: "text-sm font-semibold text-gray-900 dark:text-white mb-2") { "Categories" }

      div(class: "space-y-2") do
        @categories.each do |cat_data|
          category = cat_data[:category]
          result = results[category.category_id]
          category_result_row(category, result)
        end
      end
    end
  end

  def category_result_row(category, result)
    alt_results = secondary_category_results(category.category_id)
    divergent = alt_results.any? { |_, alt| alt && result && alt[:pass] != result[:pass] }

    div(class: "py-1.5 px-2 rounded-md bg-white dark:bg-gray-800/50") do
      div(class: "flex items-center justify-between") do
        span(class: "text-sm text-gray-700 dark:text-gray-300 truncate mr-2") { category.name }

        div(class: "flex items-center gap-1") do
          if divergent
            span(
              class: "w-1.5 h-1.5 rounded-full bg-amber-400 dark:bg-amber-500 shrink-0",
              title: "Perspectives differ on this category"
            ) { }
          end
          render Views::Assessments::CategoryStatus.new(
            category_id: category.category_id,
            category_result: result
          )
        end
      end

      # Show divergent secondary results inline
      alt_results.each do |label, alt_result|
        next unless alt_result && result && alt_result[:pass] != result[:pass]

        alt_text = alt_result[:pass] ? "Pass" : "Below"
        alt_color = alt_result[:pass] ? "text-green-600 dark:text-green-400" : "text-amber-600 dark:text-amber-400"

        div(class: "flex items-center gap-1.5 mt-0.5 ml-0.5") do
          span(class: "text-[10px] text-gray-400 dark:text-gray-500") { "#{label}:" }
          span(class: "text-[10px] font-medium #{alt_color}") { alt_text }
        end
      end
    end
  end

  # ── Promotion ──

  def promotion_section
    readiness = primary_scoring[:promotion_readiness]
    return unless readiness

    div do
      h3(class: "text-sm font-semibold text-gray-900 dark:text-white mb-2") do
        "Promotion to L#{@person_level + 1}"
      end

      if readiness[:eligible]
        div(class: "p-3 rounded-md bg-green-50 dark:bg-green-900/20 " \
                   "border border-green-200 dark:border-green-800") do
          span(class: "text-sm font-medium text-green-800 dark:text-green-300") do
            "Eligible for promotion"
          end
        end
      else
        div(class: "p-3 rounded-md bg-gray-50 dark:bg-gray-800 " \
                   "border border-gray-200 dark:border-gray-700") do
          span(class: "text-sm text-gray-600 dark:text-gray-400") { "Not yet eligible" }

          blocked = readiness[:blocked_at_next_level] || []
          if blocked.any?
            p(class: "mt-1 text-xs text-gray-500 dark:text-gray-500") do
              "#{blocked.size} blocked #{'capability'.pluralize(blocked.size)} at L#{@person_level + 1}"
            end
          end

          unless readiness[:meets_score_threshold]
            p(class: "mt-1 text-xs text-gray-500 dark:text-gray-500") do
              "Score threshold not met"
            end
          end
        end
      end

      # Secondary promotion annotations when perspectives differ
      secondary_promotion_annotations(readiness)
    end
  end

  # Shows divergent promotion eligibility from secondary perspectives.
  #
  def secondary_promotion_annotations(primary_readiness)
    secondary_scorings.each do |label, scoring|
      alt_readiness = scoring[:promotion_readiness]
      next unless alt_readiness
      next if alt_readiness[:eligible] == primary_readiness[:eligible]

      text = alt_readiness[:eligible] ? "Eligible" : "Not eligible"
      color = alt_readiness[:eligible] ? "text-green-600 dark:text-green-400" : "text-gray-500 dark:text-gray-400"

      div(class: "flex items-center gap-1.5 mt-1.5") do
        span(
          class: "w-1.5 h-1.5 rounded-full bg-amber-400 dark:bg-amber-500 shrink-0",
          title: "Divergent assessment"
        ) { }
        span(class: "text-xs text-gray-500 dark:text-gray-400") { "#{label}:" }
        span(class: "text-xs font-medium #{color}") { text }
      end
    end
  end

  # ── Blocked capabilities ──

  def blocked_capabilities_detail
    statuses = primary_scoring[:capability_statuses] || {}
    reasons  = primary_scoring[:block_reasons] || {}
    blocked_ids = statuses.select { |_, s| s == :blocked }.keys
    return if blocked_ids.empty?

    blocked_caps = @categories.flat_map { |cat| cat[:capabilities] }
                              .select { |cap| blocked_ids.include?(cap[:capability].stable_id) }

    div(class: "mt-2 p-2 rounded-md bg-red-50/50 dark:bg-red-900/10") do
      p(class: "text-xs font-medium text-red-700 dark:text-red-400 mb-1") do
        "#{blocked_caps.size} blocked #{'capability'.pluralize(blocked_caps.size)}"
      end
      ul(class: "space-y-1") do
        blocked_caps.each do |cap|
          stable_id = cap[:capability].stable_id
          li(class: "text-xs text-red-600 dark:text-red-400") do
            div(class: "flex items-center gap-1") do
              span(class: "w-1 h-1 rounded-full bg-red-400 shrink-0") { }
              plain cap[:capability].name
            end
            if reasons[stable_id]
              p(class: "text-[10px] text-red-500 dark:text-red-500 ml-2.5") { reasons[stable_id] }
            end
          end
        end
      end
    end
  end

  # ── Perspective helpers ──

  # Returns the primary scoring hash based on the current context.
  # Falls back to effective scoring if the perspective-specific scoring is nil.
  #
  # @return [Hash]
  def primary_scoring
    @primary_scoring ||=
      case @context
      when :self      then @self_scoring || @scoring
      when :manager   then @manager_scoring || @scoring
      when :alignment then @aligned_scoring || @scoring
      else @scoring
      end
  end

  # Returns an array of [label, scoring] pairs for secondary perspectives.
  # Excludes nil scorings and the primary perspective.
  #
  # @return [Array<Array(String, Hash)>]
  def secondary_scorings
    @secondary_scorings ||= begin
      all = []
      case @context
      when :self
        all << [ "Mgr", @manager_scoring ] if @manager_scoring
        all << [ "Agreed", @aligned_scoring ] if @aligned_scoring
      when :manager
        all << [ "Self", @self_scoring ] if @self_scoring
        all << [ "Agreed", @aligned_scoring ] if @aligned_scoring
      when :alignment
        all << [ "Self", @self_scoring ] if @self_scoring
        all << [ "Mgr", @manager_scoring ] if @manager_scoring
      end
      all
    end
  end

  # Returns category results from secondary perspectives for divergence display.
  #
  # @param category_id [String]
  # @return [Array<Array(String, Hash)>]
  def secondary_category_results(category_id)
    secondary_scorings.filter_map do |label, scoring|
      results = scoring[:category_results]
      next unless results

      [ label, results[category_id] ]
    end
  end

  # Determines the tier (:mastering, :meeting, :below) from a scoring hash.
  #
  # @param scoring [Hash]
  # @return [Symbol]
  def tier_for(scoring)
    if scoring[:mastering]
      :mastering
    elsif scoring[:meeting_expectations]
      :meeting
    else
      :below
    end
  end

  # ── Color helpers ──

  def performance_color(ratio)
    if ratio >= @mastery_threshold
      "text-purple-600 dark:text-purple-400"
    elsif ratio >= @meeting_expectation_threshold
      "text-green-600 dark:text-green-400"
    elsif ratio >= AMBER_THRESHOLD
      "text-amber-600 dark:text-amber-400"
    else
      "text-red-600 dark:text-red-400"
    end
  end

  def performance_bar_color(ratio)
    if ratio >= @mastery_threshold
      "bg-purple-500"
    elsif ratio >= @meeting_expectation_threshold
      "bg-green-500"
    elsif ratio >= AMBER_THRESHOLD
      "bg-amber-500"
    else
      "bg-red-500"
    end
  end
end
