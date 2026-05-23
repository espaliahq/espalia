# frozen_string_literal: true

require "test_helper"
require "rubocop"
require Rails.root.join("lib/rubocop/cop/growth_os/controllers_must_use_operations")

# Unit tests for the custom cop that enforces the Operations layer as the
# single write surface shared by controllers and the MCP server.
class RuboCop::Cop::GrowthOs::ControllersMustUseOperationsTest < ActiveSupport::TestCase
  # Runs the cop over a source string and returns the offense messages.
  #
  # @param source [String] Ruby source to inspect
  # @return [Array<String>] offense messages, in source order
  def offenses_for(source)
    cop = RuboCop::Cop::GrowthOs::ControllersMustUseOperations.new
    processed = RuboCop::ProcessedSource.new(source, RUBY_VERSION.to_f)
    commissioner = RuboCop::Cop::Commissioner.new([ cop ])
    report = commissioner.investigate(processed)
    report.offenses.reject(&:disabled?).sort_by(&:line).map(&:message)
  end

  context "direct CommandHandler instantiation" do
    should "flag a top-level Frameworks::CommandHandler.new" do
      messages = offenses_for(<<~RUBY)
        Frameworks::CommandHandler.new.add_capability(framework_id, cap_id, name: "Thinking")
      RUBY
      assert_equal 1, messages.size
      assert_match(/Operations::\*/, messages.first)
      assert_match(/Frameworks::CommandHandler/, messages.first)
    end

    should "flag PersonDevelopment::CommandHandler.new with no args" do
      messages = offenses_for(<<~RUBY)
        PersonDevelopment::CommandHandler.new.rate_self(person_id, assessment_id)
      RUBY
      assert_equal 1, messages.size
      assert_match(/PersonDevelopment::CommandHandler/, messages.first)
    end

    should "flag AssessmentCycles::CommandHandler.new on a local var assignment" do
      messages = offenses_for(<<~RUBY)
        handler = AssessmentCycles::CommandHandler.new
        handler.close_cycle(cycle_id)
      RUBY
      assert_equal 1, messages.size
      assert_match(/AssessmentCycles::CommandHandler/, messages.first)
    end

    should "flag a single-segment ::CommandHandler.new" do
      messages = offenses_for(<<~RUBY)
        CommandHandler.new.do_thing
      RUBY
      assert_equal 1, messages.size
    end
  end

  context "non-matching code" do
    should "not flag CommandHandler.new in a comment" do
      messages = offenses_for(<<~RUBY)
        # We used to call Frameworks::CommandHandler.new here.
        Operations::Frameworks::AddCapability.call(context:, params:)
      RUBY
      assert_empty messages
    end

    should "not flag Operations::* dispatches" do
      messages = offenses_for(<<~RUBY)
        Operations::Frameworks::AddCapability.call(context: pundit_user, params: cap_params)
      RUBY
      assert_empty messages
    end

    should "not flag a different .new on a const named Handler (not CommandHandler)" do
      messages = offenses_for(<<~RUBY)
        Frameworks::Repository.new.with_framework(id) { |fw| fw.create(id, name) }
      RUBY
      assert_empty messages
    end

    should "not flag a CommandHandler reference without .new" do
      messages = offenses_for(<<~RUBY)
        described_class = Frameworks::CommandHandler
      RUBY
      assert_empty messages
    end

    should "respect an inline disable comment" do
      messages = offenses_for(<<~RUBY)
        Frameworks::CommandHandler.new.add_capability(id, cap) # rubocop:disable GrowthOs/ControllersMustUseOperations
      RUBY
      assert_empty messages
    end
  end
end
