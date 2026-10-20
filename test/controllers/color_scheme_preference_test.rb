# frozen_string_literal: true

require "test_helper"

class ColorSchemePreferenceTest < ActiveSupport::TestCase
  setup { @controller = ApplicationController.new }

  def html_data_scheme(user:, dev_override: nil)
    @controller.stub(:current_user, user) do
      @controller.stub(:dev_scheme_override, dev_override) do
        @controller.send(:html_data_scheme)
      end
    end
  end

  should "be nil when signed out" do
    assert_nil html_data_scheme(user: nil)
  end

  should "be nil for auto, so the page follows the OS" do
    assert_nil html_data_scheme(user: build(:user, color_scheme: :auto))
  end

  should "be the person's explicit choice" do
    assert_equal "dark", html_data_scheme(user: build(:user, color_scheme: :dark))
    assert_equal "light", html_data_scheme(user: build(:user, color_scheme: :light))
  end

  should "let the development override win" do
    assert_equal "light", html_data_scheme(user: build(:user, color_scheme: :dark), dev_override: "light")
  end
end
