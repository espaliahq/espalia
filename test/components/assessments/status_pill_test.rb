# frozen_string_literal: true

require "test_helper"

# "In Progress" over an assessment whose every cell holds a carried value read
# as finished work left undone; the pill now says what is actually left (#480).
class Views::Assessments::StatusPillTest < ActiveSupport::TestCase
  def pill(**options)
    Nokogiri::HTML5.fragment(
      Views::Assessments::StatusPill.new(participant_status: "enrolled", has_open_cycle: true, **options).call
    ).text.strip
  end

  should "say how many carried ratings are left when nothing else is" do
    assert_equal "3 to confirm", pill(work: { unrated: 0, to_confirm: 3 })
  end

  should "stay In Progress while any cell has no value" do
    assert_equal "In Progress", pill(work: { unrated: 2, to_confirm: 3 })
  end

  should "say Complete once every cell is vetted" do
    assert_equal "Assessment Complete", pill(current_level_complete: true, work: { unrated: 0, to_confirm: 0 })
  end

  should "leave the alignment phases alone" do
    assert_equal "Aligning",
                 Nokogiri::HTML5.fragment(Views::Assessments::StatusPill.new(
                   participant_status: "aligning", has_open_cycle: true, work: { unrated: 0, to_confirm: 3 }
                 ).call).text.strip
  end
end
