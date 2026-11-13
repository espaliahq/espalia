# frozen_string_literal: true

require "test_helper"

class Views::Integrations::HrisFieldPreviewFrameTest < ActiveSupport::TestCase
  FIELD = { id: "work.customColumns.column_team", name: "Team", kind: "list" }.freeze

  def render_frame(**options)
    view_context = ApplicationController.new
      .tap { |controller| controller.request = ActionDispatch::TestRequest.create }
      .view_context
    Nokogiri::HTML5.fragment(view_context.render(Views::Integrations::HrisFieldPreviewFrame.new(**options)))
  end

  def level(units)
    { field: FIELD, target: "level", people: units.sum { it[:people] } + 1, blank: 1, withheld: 0, units: }
  end

  should "name the largest units and count the rest" do
    shown = Views::Integrations::HrisFieldPreviewFrame::UNITS_SHOWN
    units = (1..shown + 3).map { { label: "Unit #{it}", people: 1 } }

    html = render_frame(target: "level", preview: level(units))

    assert_equal shown, html.css("li").size
    assert_includes html.text, "And 3 more units."
  end

  should "say one person, not one people" do
    html = render_frame(target: "level", preview: level([ { label: "Payments", people: 1 } ]))

    assert_includes html.at_css("li").text, "1 person"
  end

  should "show a fact's counts with no unit list" do
    preview = { field: FIELD, target: "country", people: 4, with_value: 3, blank: 1, withheld: 0, would_change: 2 }

    html = render_frame(target: "country", preview:)

    assert_equal "Team as the country", html.at_css("h2").text
    assert_equal({ "Have a value" => "3", "Would change" => "2", "Blank" => "1", "Withheld by their record" => "0" },
                 html.css("dl > div").to_h { [ it.at_css("dt").text, it.at_css("dd").text ] })
    assert_empty html.css("li")
  end

  should "count unreadable values apart from blank, and only when there are any" do
    preview = { field: FIELD, target: "country", people: 4, with_value: 1, blank: 1, withheld: 0, unreadable: 2,
                would_change: 1 }

    counts = render_frame(target: "country", preview:).css("dl > div").to_h { [ it.at_css("dt").text, it.at_css("dd").text ] }

    assert_equal [ "1", "2" ], counts.values_at("Blank", "Unreadable")
  end

  should "load lazily from its source, busy until it does" do
    html = render_frame(target: "level", src: "/preview")

    frame = html.at_css("turbo-frame")
    assert_equal [ "/preview", "lazy" ], [ frame["src"], frame["loading"] ]
    assert_equal "true", html.at_css("p")["aria-busy"]
  end

  should "announce a problem" do
    html = render_frame(target: "level", problem: "The HRIS refused the stored credentials.")

    assert_equal "status", html.at_css("p")["role"]
  end
end
