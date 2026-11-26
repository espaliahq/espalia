# frozen_string_literal: true

require "test_helper"
require "rubocop"
require Rails.root.join("lib/rubocop/cop/espalia/writes_must_be_declared")

class RuboCop::Cop::Espalia::WritesMustBeDeclaredTest < ActiveSupport::TestCase
  UNNAMED = "app/operations/operations/tenants/unnamed_example.rb"
  NAMED = "app/operations/operations/tenants/set_time_zone.rb"

  # @param source [String] Ruby source to inspect
  # @param path [String] where the source lives, relative to the root
  # @return [Array<String>] offense messages, in source order
  def offenses_for(source, path: UNNAMED)
    cop = RuboCop::Cop::Espalia::WritesMustBeDeclared.new
    processed = RuboCop::ProcessedSource.new(source, RUBY_VERSION.to_f, Rails.root.join(path).to_s)
    report = RuboCop::Cop::Commissioner.new([ cop ]).investigate(processed)
    report.offenses.reject(&:disabled?).sort_by(&:line).map(&:message)
  end

  context "a file the declaration doesn't name" do
    should "flag a persistence call on a record" do
      messages = offenses_for("tenant.update!(time_zone: zone)\n")
      assert_equal 1, messages.size
      assert_match(/`update!`/, messages.first)
      assert_match(%r{config/write_ownership\.yml}, messages.first)
    end

    should "flag a bulk write on a relation and a create through an association" do
      assert_equal 2, offenses_for(<<~RUBY).size
        Person.where(tenant_id: id).update_all(manager_id: nil)
        tenant.people.create!(name: name)
      RUBY
    end

    should "flag a safe-navigation call" do
      assert_equal 1, offenses_for("proposal&.destroy!\n").size
    end

    should "flag delete, insert and update on a constant" do
      assert_equal 3, offenses_for(<<~RUBY).size
        Mcp::AccessToken.delete(id)
        Person.insert(row)
        Tenant.update(id, name: name)
      RUBY
    end

    should "flag save with keyword options only" do
      assert_equal 2, offenses_for(<<~RUBY).size
        record.save
        record.save!(validate: false)
      RUBY
    end
  end

  context "calls that write no table" do
    should "accept delete, insert and update on anything but a constant" do
      assert_empty offenses_for(<<~RUBY)
        session.delete(:return_to)
        ids.insert(0, id)
        turbo_stream.update("flash", partial)
      RUBY
    end

    should "accept a save given a positional argument" do
      assert_empty offenses_for("planning_inputs.save(table, changed_by_id: id) { |row| row }\n")
    end

    should "accept a call with no receiver" do
      assert_empty offenses_for("create(params)\n")
    end
  end

  context "a file the declaration names" do
    should "accept every persistence call" do
      assert_empty offenses_for("tenant.update!(time_zone: zone)\n", path: NAMED)
    end

    should "read its writers from config/write_ownership.yml" do
      writers = RuboCop::Cop::Espalia::WritesMustBeDeclared.declared_writers
      assert_includes writers, NAMED
      assert_not_includes writers, UNNAMED
    end

    should "take no Exclude list in .rubocop.yml, so the declaration stays the only one" do
      config = YAML.safe_load_file(Rails.root.join(".rubocop.yml"), aliases: true)
      assert_not config.fetch("Espalia/WritesMustBeDeclared").key?("Exclude")
    end
  end
end
