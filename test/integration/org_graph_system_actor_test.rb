# frozen_string_literal: true

require "test_helper"

# OrgGraph::Authorization::SYSTEM skips every policy check, so only the
# system's own work may hold it. A unit's structure and its types are a
# person's call (#494): no SYSTEM handler in app/ may change them. Retiring a
# unit withdraws its structure inside the aggregate, so the HRIS sync never
# needs to.
class OrgGraphSystemActorTest < ActiveSupport::TestCase
  STRUCTURE_COMMANDS = %w[declare_structure withdraw_structure add_level set_kind_parents remove_level define_taxonomy].freeze

  should "keep structure and type commands out of every file that builds a SYSTEM structure handler" do
    files = Dir[Rails.root.join("app/**/*.rb")].select do |path|
      File.read(path).match?(/StructureCommandHandler\.new\(actor: (?:OrgGraph::Authorization::)?SYSTEM/)
    end
    assert_not_empty files, "the scan found no SYSTEM structure handler; check its pattern"

    offenders = files.filter_map do |path|
      called = STRUCTURE_COMMANDS.select { |command| File.read(path).match?(/\.#{command}\b/) }
      "#{path.delete_prefix("#{Rails.root}/")}: #{called.join(', ')}" if called.any?
    end
    assert_empty offenders
  end

  should "run every Org Graph operation's handler as its caller" do
    source = File.read(Rails.root.join("app/operations/operations/org_graph/unit_write.rb"))

    assert_match "StructureCommandHandler.new(actor: context", source
    assert_empty Dir[Rails.root.join("app/{operations,controllers}/**/*.rb")].select { File.read(it).include?("Authorization::SYSTEM") }
  end
end
