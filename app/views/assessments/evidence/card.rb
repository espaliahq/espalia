# frozen_string_literal: true

# Renders a single evidence item inside the expanded cell of an
# assessment matrix.
#
# Shows source dot (self/manager/peer), type label, optional title,
# content, optional external-link chip, author + relative timestamp.
# A hover-revealed action menu lets the author or anyone in the
# assessee's manager chain withdraw the item; relink lives behind the
# same menu.
#
class Views::Assessments::Evidence::Card < Views::Base
  include Phlex::Rails::Helpers::TimeAgoInWords
  include Phlex::Rails::Helpers::ButtonTo

  SOURCE_DOT = {
    "self"    => "bg-emerald-500",
    "manager" => "bg-indigo-500",
    "peer"    => "bg-amber-500"
  }.freeze

  TYPE_LABEL = {
    "peer_feedback"     => "Peer feedback",
    "project_outcome"   => "Project outcome",
    "code_review"       => "Code review",
    "design_review"     => "Design review",
    "customer_feedback" => "Customer feedback",
    "incident_response" => "Incident response",
    "presentation"      => "Presentation",
    "mentoring"         => "Mentoring",
    "other"             => nil
  }.freeze

  # @param item [EvidenceItem]
  # @param assessment_id [String] for routing the withdraw action
  # @param can_withdraw [Boolean] whether the current viewer may withdraw this item
  def initialize(item:, assessment_id:, can_withdraw: false)
    @item = item
    @assessment_id = assessment_id
    @can_withdraw = can_withdraw
  end

  def view_template
    li(
      id: "evidence-#{@item.id}",
      class: "group relative flex gap-2 py-1.5 text-xs text-gray-700 dark:text-gray-200"
    ) do
      source_dot
      div(class: "min-w-0 flex-1") do
        header_line
        title_line if @item.title.present?
        content_line
        footer_line
      end
      withdraw_button if @can_withdraw
    end
  end

  private

  def source_dot
    span(
      class: "mt-1 w-2 h-2 rounded-full shrink-0 #{SOURCE_DOT[@item.source]}",
      title: @item.source.capitalize
    ) { }
  end

  def header_line
    div(class: "flex flex-wrap items-center gap-x-2 text-[11px]") do
      span(class: "font-medium text-gray-600 dark:text-gray-300") do
        type_label
      end
      external_chip if @item.external_reference&.present?
    end
  end

  def title_line
    p(class: "font-medium text-gray-900 dark:text-gray-100 mt-0.5") { @item.title }
  end

  def content_line
    p(class: "mt-0.5 text-gray-700 dark:text-gray-300 line-clamp-2") do
      @item.content
    end
  end

  def footer_line
    div(class: "mt-1 text-[10px] text-gray-400 dark:text-gray-500") do
      span { @item.author&.name || "Unknown" }
      plain " · "
      span { time_ago_in_words(@item.recorded_at) + " ago" }
    end
  end

  def type_label
    if @item.evidence_type == "other"
      @item.custom_type_label.presence || "Other"
    else
      TYPE_LABEL[@item.evidence_type] || @item.evidence_type.to_s.humanize
    end
  end

  def external_chip
    ref = @item.external_reference
    label = ref.system.presence || "link"
    if ref.url.present?
      a(href: ref.url, target: "_blank", rel: "noopener noreferrer",
        class: "inline-flex items-center gap-0.5 rounded bg-gray-100 dark:bg-gray-700 " \
               "px-1.5 py-0.5 text-[10px] text-gray-600 dark:text-gray-300 hover:bg-gray-200 " \
               "dark:hover:bg-gray-600 hover:underline") { label }
    else
      span(class: "inline-flex items-center gap-0.5 rounded bg-gray-100 dark:bg-gray-700 " \
                 "px-1.5 py-0.5 text-[10px] text-gray-600 dark:text-gray-300") { label }
    end
  end

  def withdraw_button
    button_to(
      assessment_evidence_path(@assessment_id, @item.id),
      method: :delete,
      class: "absolute top-1 right-1 opacity-0 group-hover:opacity-100 transition-opacity " \
             "rounded p-1 text-gray-400 hover:text-red-600 hover:bg-red-50 " \
             "dark:hover:bg-red-900/30",
      form: { data: { turbo_confirm: "Withdraw this evidence?" } },
      aria: { label: "Withdraw evidence" }
    ) do
      span(class: "block w-3 h-3", aria_hidden: "true") { "×" }
    end
  end
end
