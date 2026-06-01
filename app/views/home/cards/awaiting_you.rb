# frozen_string_literal: true

# Content for the "Awaiting you" card — direct reports who still need this
# manager's rating or alignment in an open cycle.
class Views::Home::Cards::AwaitingYou < Views::Base
  PREVIEW_LIMIT = 5

  # @param reports [Array<Hash>] [{ person:, cycle:, status: }, ...]
  def initialize(reports:)
    @reports = reports
  end

  def view_template
    render Components::Kit::Card.new(title: "Awaiting you") do |card|
      card.body do
        summary_line
        report_list
      end
      card.actions { review_link }
    end
  end

  private

  def summary_line
    count = @reports.size
    p(class: "text-sm text-gray-600 dark:text-gray-300") do
      "#{count} #{count == 1 ? "report" : "reports"} need your rating or alignment."
    end
  end

  def report_list
    return if @reports.empty?

    ul(class: "mt-3 space-y-1") do
      @reports.first(PREVIEW_LIMIT).each do |report|
        li(class: "text-sm text-gray-700 dark:text-gray-300") do
          plain report[:person]&.name || "Unknown"
          span(class: "text-gray-400 dark:text-gray-500") { " · #{report[:cycle].name}" }
        end
      end
      if @reports.size > PREVIEW_LIMIT
        li(class: "text-sm text-gray-400 dark:text-gray-500") do
          "+#{@reports.size - PREVIEW_LIMIT} more"
        end
      end
    end
  end

  def review_link
    a(
      href: assessments_path,
      data: { turbo_frame: "_top" },
      class: "inline-flex items-center min-h-11 text-sm font-medium text-primary hover:underline"
    ) { "Review team →" }
  end
end
