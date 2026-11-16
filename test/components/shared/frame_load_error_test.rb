# frozen_string_literal: true

require "test_helper"

class Components::Shared::FrameLoadErrorTest < ActiveSupport::TestCase
  def render_error(**options)
    Nokogiri::HTML5.fragment(Components::Shared::FrameLoadError.new(id: "figures-error", subject: "the figures", **options).call)
  end

  should "draw a hidden alert with its message and a Retry" do
    error = render_error.at_css("#figures-error")

    assert_equal [ "alert", "", "error" ], [ error["role"], error["hidden"], error["data-frame-error-target"] ]
    assert_includes error.text, "Couldn't load the figures. Try again"
    assert_equal "frame-error#retry", error.at_css("button")["data-action"]
  end

  should "say it in one quiet line when inline" do
    error = render_error(inline: true).at_css("p#figures-error")

    assert_equal [ "alert", "", "error" ], [ error["role"], error["hidden"], error["data-frame-error-target"] ]
    assert_equal "Couldn't load the figures.Retry", error.text
    assert_equal "frame-error#retry", error.at_css("button")["data-action"]
    assert_nil error.at_css("div")
    assert_not_includes error["class"].split, "p-6"
  end
end
