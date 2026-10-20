# frozen_string_literal: true

require "test_helper"

# Colours that carry assessment meaning come from the domain tokens in
# app/assets/tailwind/theme/domain.css, so a theme can set them (#541).
class DomainPaletteTokensTest < ActiveSupport::TestCase
  PALETTE_STEP = /(?<![\w-])(?:bg|text|border|ring|fill|stroke)-[a-z]+-\d{2,3}(?![\w-])/

  PALETTES = {
    "frequency palette" => Views::Assessments::FrequencyPalette::CONFIG.values.flat_map(&:values),
    "score tone" => Views::Assessments::Concerns::ScoreScale::TONE_TEXT.values +
      Views::Assessments::Concerns::ScoreScale::TONE_BAR.values,
    "assessment activity" => Views::Assessments::Activity::Entry::KIND_DOT.values,
    "framework activity" => Views::Frameworks::Activity::Entry::KIND_DOT.values,
    "home activity" => Views::Home::Cards::RecentActivity::DOT_COLOR.values,
    "calibration log" => Views::CalibrationSessions::SessionLog::KIND_DOT.values,
    "evidence source" => Views::Assessments::Evidence::Card::SOURCE_DOT.values
  }.freeze

  PALETTES.each do |name, classes|
    should "colour the #{name} from tokens, not palette steps" do
      steps = classes.grep(String).flat_map { |c| c.scan(PALETTE_STEP) }.uniq
      assert_empty steps, "Use the domain tokens in theme/domain.css instead of: #{steps.join(', ')}"
    end
  end

  should "define a utility for every token class the palettes use" do
    css = Rails.root.join("app/assets/tailwind/theme/domain.css").read
    defined = css.scan(/--(background|text|border)-color-([\w-]+):/).map do |property, name|
      "#{{ "background" => "bg" }.fetch(property, property)}-#{name}"
    end
    used = PALETTES.values.flatten.grep(String).flat_map(&:split)
      .grep(/\A(?:bg|text|border)-(?:rating|score|activity)-/)
    assert_empty used.uniq - defined
  end
end
