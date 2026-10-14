# frozen_string_literal: true

require "test_helper"

# The header pill's finished label says whose move it is: an assessee who has
# rated every current-level cell is "Ready for alignment", because the next
# step is the manager's. A manager who has finished their own ratings still
# reads "Assessment Complete".
class Views::Assessments::StatusPillTest < ActiveSupport::TestCase
  def render_pill(context:, complete: true, status: "started", open: true)
    Views::Assessments::StatusPill.new(
      participant_status: status, has_open_cycle: open, context: context, current_level_complete: complete
    ).call
  end

  context "the assessee's view" do
    should "read Ready for alignment once every current-level cell is rated" do
      html = render_pill(context: :self)

      doc = Nokogiri::HTML5.fragment(html)
      trigger = doc.at_css("button[aria-describedby]")

      assert_equal "Ready for alignment", trigger&.text&.strip
      assert_includes doc.at_css("##{trigger["aria-describedby"]}").text, "Your manager starts alignment next."
      assert_nil doc.at_css("[title]"), "a title is unreachable by keyboard; the definition tip carries it"
      assert_not_includes html, "Assessment Complete"
    end

    should "read In Progress until then" do
      html = render_pill(context: :self, complete: false)

      assert_includes html, "In Progress"
      assert_not_includes html, "Ready for alignment"
    end

    should "give way to the alignment phase once it starts" do
      html = render_pill(context: :self, status: "aligning")

      assert_includes html, "Aligning"
      assert_not_includes html, "Ready for alignment"
    end
  end

  context "the manager's view" do
    should "read Assessment Complete once the manager has rated every current-level cell" do
      html = render_pill(context: :manager)

      assert_includes html, "Assessment Complete"
      assert_not_includes html, "Ready for alignment"
    end
  end
end
