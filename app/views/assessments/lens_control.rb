# frozen_string_literal: true

# The header's shortcode chip, which is also where a lens is chosen (ADR-22).
#
# The chip names the role and level the page is read against — "E3" on the
# record, "PM3" in the exploring tone under a lens — and opens a menu: the
# ladder of the role being read, so a vertical lens is one click, and
# "Another role…", which opens {Views::Assessments::LensRoleModal}. Every
# entry is a plain link, so a lens is a URL that survives refresh, Back and
# sharing.
class Views::Assessments::LensControl < Views::Base
  HOME_CHIP = "bg-gray-100 dark:bg-gray-800 text-gray-600 dark:text-gray-300"
  LENS_CHIP = "bg-sky-100 dark:bg-sky-900/40 text-sky-800 dark:text-sky-200 ring-1 ring-sky-300 dark:ring-sky-700"
  ITEM = "flex w-full items-center gap-2 px-4 py-2 text-left text-sm text-gray-700 dark:text-gray-200 " \
         "hover:bg-gray-100 dark:hover:bg-gray-700 focus-visible:bg-gray-100 dark:focus-visible:bg-gray-700 " \
         "focus-visible:outline-hidden"

  # @param lens [Assessments::Lens]
  # @param assessment_id [String]
  # @param whose [String] "your" or the assessee's first name with "'s"
  def initialize(lens:, assessment_id:, whose: "your")
    @lens = lens
    @assessment_id = assessment_id
    @whose = whose
  end

  ID = "assessment-lens-control"

  def view_template
    div(id: ID, class: "inline-block") { dropdown }
  end

  private

  def dropdown
    render Components::Kit::Dropdown.new(align: :left) do |dropdown|
      dropdown.trigger(label: "Reading against #{@lens.code} — choose a role or level") do
        span(
          id: "assessment-lens-chip",
          class: "inline-flex items-center gap-1 px-1.5 py-0.5 rounded font-mono text-xs font-semibold " \
                 "tracking-wide cursor-pointer #{@lens.home? ? HOME_CHIP : LENS_CHIP}",
          data: { lens: @lens.home? ? "home" : "exploring" }
        ) do
          plain @lens.code
          span(class: "text-[10px] leading-none", aria_hidden: "true") { "▾" }
        end
      end
      dropdown.menu(width: "w-64") do
        ladder
        div(class: "my-1 border-t border-gray-100 dark:border-gray-700", role: "none")
        back_home_item unless @lens.home?
        another_role_item
      end
    end
  end

  def ladder
    div(class: "px-4 py-1.5", role: "none") do
      p(class: "text-xs font-semibold text-gray-600 dark:text-gray-300 uppercase tracking-wider") do
        @lens.role.name
      end
    end
    @lens.role.levels.sort_by(&:ordinal).each { |level| ladder_item(level) }
  end

  def ladder_item(level)
    current = level.ordinal == @lens.level.ordinal
    a(
      href: assessment_path(@assessment_id, @lens.params_for(role_id: @lens.role.role_id, ordinal: level.ordinal)),
      role: "menuitem",
      class: "#{ITEM} #{current ? 'font-semibold' : ''}",
      aria: { current: (current ? "page" : nil) }.compact
    ) do
      span(class: "w-4 shrink-0 text-gray-500", aria_hidden: "true") { current ? "✓" : "" }
      span(class: "font-mono text-xs w-10 shrink-0") { "#{@lens.role.code}#{level.ordinal}" }
      whitespace
      span(class: "min-w-0 truncate") { level.title }
      if @lens.home_role? && level.ordinal == @lens.home_level.ordinal
        whitespace
        home_note
      end
    end
  end

  def home_note
    span(class: "ml-auto shrink-0 text-[11px] text-gray-500 dark:text-gray-400") do
      @whose == "your" ? "your level" : "#{@whose} level"
    end
  end

  def back_home_item
    a(href: assessment_path(@assessment_id), role: "menuitem", class: ITEM) do
      span(class: "w-4 shrink-0", aria_hidden: "true") { "←" }
      span { "Back to #{@lens.home_code}" }
    end
  end

  def another_role_item
    button(
      type: "button",
      role: "menuitem",
      class: ITEM,
      data: { action: "click->dropdown#close click->modal#open",
              modal_target_id: Views::Assessments::LensRoleModal::ID }
    ) do
      span(class: "w-4 shrink-0", aria_hidden: "true") { "" }
      span { "Another role…" }
    end
  end
end
