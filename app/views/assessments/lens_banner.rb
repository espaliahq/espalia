# frozen_string_literal: true

# The one line that replaces the status pill while a lens is on (ADR-22):
# what the page is read against, that the record is untouched, and the way
# back. The status pill describes the record's lifecycle, which a lens
# neither reads nor changes, so the two never show together.
class Views::Assessments::LensBanner < Views::Base
  ID = "assessment-lens-banner"

  # @param lens [Assessments::Lens]
  # @param assessment_id [String]
  # @param assessee_name [String, nil] nil for the assessee's own view
  def initialize(lens:, assessment_id:, assessee_name: nil)
    @lens = lens
    @assessment_id = assessment_id
    @first_name = assessee_name.to_s.split.first
  end

  def view_template
    p(id: ID, class: "basis-full text-sm text-gray-700 dark:text-gray-200") do
      plain "Viewing #{whose} ratings against "
      strong(class: "font-semibold text-gray-900 dark:text-white") { @lens.label }
      plain ". #{whose.capitalize} #{@lens.home_code} assessment is unchanged. "
      a(href: assessment_path(@assessment_id),
        class: "font-medium text-primary hover:underline whitespace-nowrap rounded-sm " \
               "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-primary") do
        "← Back to #{@lens.home_code}"
      end
    end
  end

  private

  def whose
    @first_name.present? ? "#{@first_name}'s" : "your"
  end
end
