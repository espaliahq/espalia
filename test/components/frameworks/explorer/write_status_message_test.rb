# frozen_string_literal: true

require "test_helper"

class Views::Frameworks::Explorer::WriteStatusMessageTest < ActiveSupport::TestCase
  def render_message(tone)
    html = Views::Frameworks::Explorer::WriteStatusMessage.new(message: "Saved", tone: tone).call
    Nokogiri::HTML5.fragment(html)
  end

  should "leave the announcing to the WriteStatus region it renders into" do
    %i[ok error].each do |tone|
      assert_empty render_message(tone).css("[role=status], [role=alert]"), "#{tone} nests a live region"
    end
  end
end
