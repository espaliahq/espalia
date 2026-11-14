# frozen_string_literal: true

require "test_helper"
require "rake"

class OrgGraphPeopleTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    %w[org_graph:people:cut_over org_graph:people:revert].each { Rake::Task[it].reenable }

    @tenant = create(:tenant)
    @person = ActsAsTenant.with_tenant(@tenant) { create(:person, tenant: @tenant, name: "Ada Lovelace", email: "ada@example.com") }
  end

  should "dry-run by default, printing ids and counts but never a name or an email" do
    output = capture_io { Rake::Task["org_graph:people:cut_over"].invoke(@tenant.id) }.first

    assert_includes output, "recorded from their row: 1\n  #{@person.id}"
    assert_includes output, "cut over: no"
    assert_no_match(/leavers dated by/, output)
    assert_no_match(/Ada|ada@example.com/, output)
    assert_not @tenant.reload.org_graph_people_projected?
  end

  should "count leavers by where their leaving date came from" do
    ActsAsTenant.with_tenant(@tenant) { @person.update!(status: "inactive") }

    output = capture_io { Rake::Task["org_graph:people:cut_over"].invoke(@tenant.id) }.first

    assert_includes output, "leavers dated by first recorded: 1"
  end

  should "cut over with APPLY=1, and revert" do
    with_env("APPLY" => "1") { capture_io { Rake::Task["org_graph:people:cut_over"].invoke(@tenant.id) } }
    assert @tenant.reload.org_graph_people_projected?

    capture_io { Rake::Task["org_graph:people:revert"].invoke(@tenant.id) }
    assert_not @tenant.reload.org_graph_people_projected?
  end

  private

  def with_env(values)
    previous = values.keys.to_h { [ it, ENV[it] ] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end
end
