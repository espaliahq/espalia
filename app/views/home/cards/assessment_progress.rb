# frozen_string_literal: true

# Content for the "Your assessment progress" card — one open cycle the viewer
# is assessing themselves in. A teaser that nudges into the self-assessment.
class Views::Home::Cards::AssessmentProgress < Views::Base
  STATUS_LABELS = {
    "in_progress" => [ "Not started", :default ],
    "started" => [ "In progress", :info ],
    "aligning" => [ "Aligning", :warning ],
    "aligned" => [ "Aligned", :success ]
  }.freeze

  # @param state [Hash, nil] { cycle:, assignment:, status:, self_rated_count: }
  def initialize(state:)
    @state = state
  end

  def view_template
    return empty unless @state

    render Components::Kit::Card.new do |card|
      card.body do
        header
        detail_line
        rated_line
      end
      card.actions { continue_link }
    end
  end

  private

  def header
    div(class: "flex items-start justify-between gap-3") do
      div do
        p(class: "text-xs font-medium uppercase tracking-wide text-gray-600 dark:text-gray-300") do
          "Your assessment"
        end
        h2(class: "text-base font-semibold text-gray-900 dark:text-white") { @state[:cycle].name }
      end
      label, variant = STATUS_LABELS.fetch(@state[:status], [ @state[:status].to_s.humanize, :default ])
      render Components::Kit::Badge.new(label, variant: variant)
    end
  end

  def detail_line
    return unless @state[:assignment]

    p(class: "mt-2 text-sm text-gray-600 dark:text-gray-300") do
      [ @state[:assignment].role&.name, @state[:assignment].level&.title ].compact.join(" · ")
    end
  end

  def rated_line
    p(class: "mt-1 text-sm text-gray-600 dark:text-gray-300") do
      count = @state[:self_rated_count]
      "#{count} #{count == 1 ? "capability" : "capabilities"} rated so far"
    end
  end

  def continue_link
    href = @state[:assignment] ? assessment_path(@state[:assignment]) : assessments_path
    a(
      href: href,
      data: { turbo_frame: "_top" },
      class: "inline-flex items-center min-h-11 text-sm font-medium text-primary-ink hover:underline"
    ) { "#{cta_verb} self-assessment →" }
  end

  # "Start" until the person themselves records a rating this cycle. Keyed off
  # the self side, not the row-level progress status — that status also flips
  # on the manager's first rating — so the verb always agrees with the
  # assessments index's own-card CTA.
  # @return [String]
  def cta_verb
    @state[:self_started] ? "Continue" : "Start"
  end

  def empty
    render Components::Kit::Card.new do |card|
      card.body do
        p(class: "text-sm text-gray-600 dark:text-gray-300") { "No open assessment." }
      end
    end
  end
end
