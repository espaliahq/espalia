# frozen_string_literal: true

# @label Prose
class Kit::ProsePreview < Lookbook::Preview
  # @param text textarea
  # @param size select { choices: [text-sm, text-xs, text-base] }
  def playground(text: "Priya ran the **incident review** for the payments outage and wrote it up in [the RFC](https://example.com).\nThe team now follows her runbook.", size: "text-sm")
    render Components::Kit::Prose.new(text, class: "#{size} text-gray-700 dark:text-gray-200")
  end

  # @!group Content

  def paragraph
    render Components::Kit::Prose.new(
      "Tom has become the person the team goes to when a design review stalls. He asks the question nobody " \
      "else wants to ask, and he does it kindly. In the last quarter he unblocked three reviews that had been " \
      "open for more than two weeks.",
      class: "text-sm text-gray-700 dark:text-gray-200"
    )
  end

  def emphasis_and_links
    render Components::Kit::Prose.new(
      "Aisha's research plan was **clear** and _well scoped_. See the [interview guide](https://example.com) " \
      "and her ~~first~~ second synthesis at https://example.com/synthesis.",
      class: "text-sm text-gray-700 dark:text-gray-200"
    )
  end

  def lists
    render Components::Kit::Prose.new(
      "What went well:\n\n- Shipped the onboarding checklist two weeks early\n- Paired with two new starters\n\n" \
      "Next steps:\n\n1. Lead the Q1 planning session\n2. Write the on-call guide",
      class: "text-sm text-gray-700 dark:text-gray-200"
    )
  end

  def quote_and_code
    render Components::Kit::Prose.new(
      "> I'd love more detail on how you chose the rollout order.\n\n" \
      "The flag is `checkout_v2`; it now defaults to off.",
      class: "text-sm text-gray-700 dark:text-gray-200"
    )
  end

  def line_breaks
    render Components::Kit::Prose.new(
      "Strengths: mentoring, written communication\nGrowth area: estimating larger pieces of work",
      class: "text-sm text-gray-700 dark:text-gray-200"
    )
  end

  def suggestion_rationale
    render Components::Kit::Prose.new(
      "\"Owns delivery\" reads as project management. At L3 we mean _owns the outcome_, including follow-up after launch.",
      class: "mt-2 pl-2 border-l-2 border-gray-200 dark:border-gray-700 text-[11px] text-gray-600 dark:text-gray-300"
    )
  end

  # @!endgroup

  # @!group Sanitised input

  def typed_html_is_escaped
    render Components::Kit::Prose.new(
      "Use <strong>bold</strong> sparingly. <script>alert('hi')</script>",
      class: "text-sm text-gray-700 dark:text-gray-200"
    )
  end

  def image_becomes_link
    render Components::Kit::Prose.new(
      "Here's the dashboard: ![Weekly active users](https://example.com/wau.png)",
      class: "text-sm text-gray-700 dark:text-gray-200"
    )
  end

  def hash_line_is_not_a_heading
    render Components::Kit::Prose.new(
      "# 3 on the priority list is the hiring plan.",
      class: "text-sm text-gray-700 dark:text-gray-200"
    )
  end

  def blank
    render Components::Kit::Prose.new(nil, class: "text-sm text-gray-700 dark:text-gray-200")
  end

  # @!endgroup
end
