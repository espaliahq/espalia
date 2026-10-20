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

  # Shown before alignment once every current-level cell carries the person's
  # own vetted rating: their part is done and the next move is the manager's.
  READY_FOR_ALIGNMENT = [ Views::Assessments::StatusPill::READY_FOR_ALIGNMENT, :success ].freeze

  # @param state [Hash, nil] { cycle:, assignment:, status:, self_rated_count:, self_started:, self_complete: }
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
        p(class: "text-xs font-medium uppercase tracking-wide text-muted") do
          "Your assessment"
        end
        h2(class: "text-base font-semibold text-default") { @state[:cycle].name }
      end
      label, variant = status_label
      div(class: "flex flex-col items-end gap-1") do
        render Components::Kit::Badge.new(label, variant: variant)
        lens_alignment_chips
      end
    end
  end

  def status_label
    return READY_FOR_ALIGNMENT if ready_for_alignment?

    STATUS_LABELS.fetch(@state[:status], [ @state[:status].to_s.humanize, :default ])
  end

  def ready_for_alignment?
    @state[:self_complete] && AssessmentCycleProgress::INDIVIDUAL_RATING_STATUSES.include?(@state[:status])
  end

  # "Aligning · PM3" beside the home status (ADR-22): alignment the manager
  # started against another role, linking into its lens.
  def lens_alignment_chips
    alignments = @state[:lens_alignments] || []
    return if alignments.empty? || @state[:assignment].nil?

    render Views::Assessments::LensAlignmentChips.new(alignments: alignments, assessment_id: @state[:assignment].id)
  end

  def detail_line
    return unless @state[:assignment]

    p(class: "mt-2 text-sm text-muted") do
      [ @state[:assignment].role&.name, @state[:assignment].level&.title ].compact.join(" · ")
    end
  end

  def rated_line
    p(class: "mt-1 text-sm text-muted") do
      count = @state[:self_rated_count]
      "#{count} #{count == 1 ? "capability" : "capabilities"} rated so far"
    end
  end

  def continue_link
    href = @state[:assignment] ? assessment_path(@state[:assignment]) : assessments_path
    a(
      href: href,
      data: { turbo_frame: "_top" },
      class: "inline-flex items-center min-h-11 text-sm font-medium text-brand hover:underline"
    ) { "#{cta_verb} self-assessment →" }
  end

  # "Start" until the person themselves records a rating this cycle. Keyed off
  # the self side, not the row-level progress status — that status also flips
  # on the manager's first rating — so the verb always agrees with the
  # assessments index's own-card CTA. "Review" only while the person waits
  # for alignment — once it starts there is work to do again.
  # @return [String]
  def cta_verb
    return "Review" if ready_for_alignment?

    @state[:self_started] ? "Continue" : "Start"
  end

  def empty
    render Components::Kit::Card.new do |card|
      card.body do
        p(class: "text-sm text-muted") { "No open assessment." }
      end
    end
  end
end
