# frozen_string_literal: true

require "test_helper"
require "rubocop"
require Rails.root.join("lib/rubocop/cop/system_tests/flake_prone_click")

# Unit tests for the custom cop that guards against the recurring system-test
# flake class (Selenium pointer-click / modal-registration drops on starved CI).
class RuboCop::Cop::SystemTests::FlakeProneClickTest < ActiveSupport::TestCase
  # Runs the cop over a source string and returns the offense messages.
  #
  # @param source [String] Ruby source to inspect
  # @return [Array<String>] offense messages, in source order
  def offenses_for(source)
    cop = RuboCop::Cop::SystemTests::FlakeProneClick.new
    processed = RuboCop::ProcessedSource.new(source, RUBY_VERSION.to_f)
    commissioner = RuboCop::Cop::Commissioner.new([ cop ])
    report = commissioner.investigate(processed)
    report.offenses.reject(&:disabled?).sort_by(&:line).map(&:message)
  end

  context "accept_confirm" do
    should "flag a bare accept_confirm with a block" do
      messages = offenses_for(<<~RUBY)
        accept_confirm { click_button "Delete" }
      RUBY
      assert_equal 1, messages.size
      assert_match(/auto_confirm/, messages.first)
    end

    should "flag accept_confirm with a matcher argument" do
      messages = offenses_for(<<~RUBY)
        accept_confirm(/Are you sure/) { click_button "Delete" }
      RUBY
      assert_equal 1, messages.size
    end

    should "not flag auto_confirm" do
      messages = offenses_for(<<~RUBY)
        auto_confirm { click_button "Delete" }
      RUBY
      assert_empty messages
    end
  end

  context "Stimulus-action clicks" do
    should "flag find with a data-action selector then click" do
      messages = offenses_for(<<~RUBY)
        find("[data-action='dropdown#toggle']").click
      RUBY
      assert_equal 1, messages.size
      assert_match(/execute_script/, messages.first)
    end

    should "flag an interpolated data-action selector" do
      messages = offenses_for(<<~'RUBY')
        find("[data-action='click->matrix#focusCategory'][data-category-id='#{@cat_id}']").click
      RUBY
      assert_equal 1, messages.size
    end

    should "flag first(...) with a data-action selector" do
      messages = offenses_for(<<~RUBY)
        first("[data-action='dropdown#toggle']").click
      RUBY
      assert_equal 1, messages.size
    end

    should "flag a scoped find with a data-action selector" do
      # The receiver is deliberately unconstrained: a scoped find drops its
      # click exactly like a top-level one.
      messages = offenses_for(<<~RUBY)
        row.find("[data-action='dropdown#toggle']").click
      RUBY
      assert_equal 1, messages.size
      assert_match(/execute_script/, messages.first)
    end

    should "not flag a click on a plain id selector" do
      messages = offenses_for(<<~RUBY)
        find("#evidence-card").click
      RUBY
      assert_empty messages
    end

    should "not flag a JS-dispatched click" do
      messages = offenses_for(<<~'RUBY')
        page.execute_script("document.querySelector(\"[data-action='dropdown#toggle']\").click()")
      RUBY
      assert_empty messages
    end
  end

  context "Escape key dispatch" do
    should "flag send_keys(:escape)" do
      messages = offenses_for(<<~RUBY)
        find("body").send_keys(:escape)
      RUBY
      assert_equal 1, messages.size
      assert_match(/press_escape/, messages.first)
    end

    should "flag :escape nested one array level deep" do
      messages = offenses_for(<<~RUBY)
        find("body").send_keys([ :shift, :escape ])
      RUBY
      assert_equal 1, messages.size
      assert_match(/press_escape/, messages.first)
    end

    should "not flag send_keys with an unguarded key" do
      messages = offenses_for(<<~RUBY)
        find("body").send_keys(:enter)
      RUBY
      assert_empty messages
    end

    should "not flag send_keys with plain text" do
      messages = offenses_for(<<~RUBY)
        find("#search").send_keys("some text")
      RUBY
      assert_empty messages
    end
  end

  context "Tab key dispatch" do
    should "flag send_keys(:tab)" do
      messages = offenses_for(<<~RUBY)
        find("body").send_keys(:tab)
      RUBY
      assert_equal 1, messages.size
      assert_match(/press_tab/, messages.first)
    end

    should "flag :tab nested one array level deep" do
      messages = offenses_for(<<~RUBY)
        find("body").send_keys([ :shift, :tab ])
      RUBY
      assert_equal 1, messages.size
      assert_match(/press_tab/, messages.first)
    end

    # Both keys are checked over the same `send_keys` node, but RuboCop
    # dedupes offenses by source range, so a call carrying both reports
    # ONE — the Esc message, checked first. Pinned so the collapse is a
    # known property rather than a surprise: the combination is not a real
    # pattern, and either message points at the same remedy.
    should "report a single offense for a call carrying both keys" do
      messages = offenses_for(<<~RUBY)
        find("body").send_keys([ :escape, :tab ])
      RUBY
      assert_equal 1, messages.size
      assert_match(/press_escape/, messages.first)
    end
  end
end
