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

    should "flag the counter, bulk and find-or-create writers" do
      assert_equal 5, offenses_for(<<~RUBY).size
        Tenant.update_counters(id, people_count: 1)
        Person.where(tenant_id: id).delete_by(state: "left")
        Person.where(tenant_id: id).touch_all
        record.update_attribute!(:name, name)
        Person.where(email: email).first_or_create!
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

    should "flag delete and update on a query built from a constant" do
      assert_equal 2, offenses_for(<<~RUBY).size
        Person.where(manager_id: id).update(manager_id: nil)
        Person.find(id).delete
      RUBY
    end

    should "flag update on a record in a variable or an association" do
      assert_equal 3, offenses_for(<<~RUBY).size
        current_user.update(color_scheme: scheme)
        @tenant.update(name: name)
        tenant.people.update(manager_id: nil)
      RUBY
    end

    should "flag update on a record held in a local named like a request object" do
      assert_equal 2, offenses_for(<<~RUBY).size
        session = Tenant.find(id)
        session.update(name: name)
        params = Person.find(id)
        params.update(name: name)
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
        Rails.cache.delete(key)
        tenant.people.delete(person)
      RUBY
    end

    should "accept update on the request's own objects and on a literal" do
      assert_empty offenses_for(<<~RUBY)
        session.update(return_to: path)
        params.update(page: 1)
        cookies.update(scheme: scheme)
        flash.update(notice: text)
        headers.update("X-Id" => id)
        { a: 1 }.update(b: 2)
      RUBY
    end

    should "accept a save given a positional argument" do
      assert_empty offenses_for("planning_inputs.save(table, changed_by_id: id) { |row| row }\n")
    end

    should "accept a call with no receiver" do
      assert_empty offenses_for("create(params)\n")
    end
  end

  context "the wider scope" do
    should "flag a write in a query file" do
      assert_equal 1, offenses_for("Person.where(id: ids).update_all(state: \"left\")\n", path: "app/queries/example_query.rb").size
    end

    should "include every directory the rule covers" do
      config = YAML.safe_load_file(Rails.root.join(".rubocop.yml"), aliases: true)
      included = config.fetch("Espalia/WritesMustBeDeclared").fetch("Include")
      %w[operations controllers jobs integrations contexts queries policies views components].each do |dir|
        assert_includes included, "app/#{dir}/**/*.rb"
      end
    end

    should "pass a write under a projections directory or app/read_models" do
      assert_empty offenses_for("Person.where(id: id).update_all(state: state)\n", path: "app/contexts/org_graph/projections/members.rb")
      assert_empty offenses_for("record.update!(state: state)\n", path: "app/read_models/example.rb")
    end

    should "pass a command on an aggregate the repository yields" do
      assert_empty offenses_for(<<~RUBY, path: "app/contexts/frameworks/example_handler.rb")
        @repository.with_framework(framework_id) do |framework|
          framework.create(framework_id, name)
        end
      RUBY
    end

    should "pass a command on an aggregate the repository yields as _1 or it" do
      assert_empty offenses_for(<<~RUBY, path: "app/contexts/frameworks/example_handler.rb")
        @repository.with_framework(framework_id) { _1.create(framework_id, name) }
        @repository.with_framework(framework_id) { it.create(framework_id, name) }
      RUBY
    end

    should "flag a record that a nearer _1 or it block yields" do
      assert_equal 2, offenses_for(<<~RUBY, path: "app/contexts/frameworks/example_handler.rb").size
        @repository.with_framework(framework_id) { |framework| records.each { _1.destroy! } }
        @repository.with_framework(framework_id) { records.each { it.destroy! } }
      RUBY
    end

    should "flag a record written in the repository call's own arguments" do
      assert_equal 1, offenses_for(<<~RUBY, path: "app/contexts/frameworks/example_handler.rb").size
        framework = FrameworkState::Framework.find(id)
        @repository.with_framework(framework.update!(name: name) && framework.id) { |framework| framework.create(id, name) }
      RUBY
    end

    should "flag only the argument when the same call is also the aggregate's command" do
      assert_equal 1, offenses_for(<<~RUBY, path: "app/contexts/frameworks/example_handler.rb").size
        framework = FrameworkState::Framework.find(id)
        @repository.with_framework(framework.create(id, name)) { |framework| framework.create(id, name) }
      RUBY
    end

    should "pass the aggregate used inside a nested block that doesn't rebind it" do
      assert_empty offenses_for(<<~RUBY, path: "app/contexts/frameworks/example_handler.rb")
        @repository.with_framework(framework_id) do |framework|
          roles.each { |role| framework.create(framework_id, role) }
        end
      RUBY
    end

    should "flag a record in a nearer block that rebinds the aggregate's name" do
      assert_equal 1, offenses_for(<<~RUBY, path: "app/contexts/frameworks/example_handler.rb").size
        @repository.with_framework(framework_id) do |framework|
          FrameworkState::Framework.all.each { |framework| framework.destroy! }
        end
      RUBY
    end

    should "flag the same call on a block argument of anything else" do
      assert_equal 1, offenses_for(<<~RUBY, path: "app/contexts/frameworks/example.rb").size
        tenants.each { |tenant| tenant.update(name: name) }
      RUBY
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
