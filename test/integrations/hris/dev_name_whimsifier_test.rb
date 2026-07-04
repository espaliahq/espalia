# frozen_string_literal: true

require "test_helper"

class Hris::DevNameWhimsifierTest < ActiveSupport::TestCase
  def build_attrs
    {
      external_id: "bob-001",
      email: "alice@example.com",
      name: "Alice Smith",
      job_title: "Software Engineer",
      hris_raw_data: {
        "id" => "bob-001",
        "email" => "alice@example.com",
        "firstName" => "Alice",
        "surname" => "Smith",
        "displayName" => "Alice Smith",
        "work" => {
          "title" => "Software Engineer",
          "reportsTo" => {
            "id" => "bob-002",
            "email" => "bob@example.com",
            "firstName" => "Bob",
            "surname" => "Jones",
            "displayName" => "Bob Jones"
          }
        }
      }
    }
  end

  context ".whimsical_name" do
    should "be deterministic for the same seed" do
      assert_equal Hris::DevNameWhimsifier.whimsical_name("bob-001"),
                   Hris::DevNameWhimsifier.whimsical_name("bob-001")
    end

    should "compose from the curated whimsical word lists" do
      first, last = Hris::DevNameWhimsifier.whimsical_name("bob-001").split(" ")

      assert_includes Hris::DevNameWhimsifier::FIRST_NAMES, first
      stem = Hris::DevNameWhimsifier::SURNAME_STEMS.find { |s| last.start_with?(s) }
      assert stem, "surname #{last} does not start with a known stem"
      assert_includes Hris::DevNameWhimsifier::SURNAME_ENDINGS, last.delete_prefix(stem)
    end

    should "spread surnames widely enough that an org-sized cohort rarely collides" do
      surnames = (1..200).map { |i| Hris::DevNameWhimsifier.whimsical_name("emp-#{i}").split(" ").last }

      # 512 possible surnames; 200 seeds should stay overwhelmingly distinct
      # (deterministic — this pins the composed-surname pool size).
      assert_operator surnames.uniq.length, :>=, 160
      assert_operator surnames.tally.values.max, :<=, 4
    end
  end

  context ".whimsify" do
    should "replace the mapped name with the pseudonym" do
      result = Hris::DevNameWhimsifier.whimsify(build_attrs)

      assert_equal Hris::DevNameWhimsifier.whimsical_name("bob-001"), result[:name]
      refute_includes result[:name], "Alice"
    end

    should "scrub name fields in the raw payload" do
      raw = Hris::DevNameWhimsifier.whimsify(build_attrs)[:hris_raw_data]
      first, last = Hris::DevNameWhimsifier.whimsical_name("bob-001").split(" ")

      assert_equal first, raw["firstName"]
      assert_equal last, raw["surname"]
      assert_equal "#{first} #{last}", raw["displayName"]
    end

    should "scrub the manager's reportsTo names using the manager's own seed" do
      reports_to = Hris::DevNameWhimsifier.whimsify(build_attrs)[:hris_raw_data]
                                          .dig("work", "reportsTo")

      assert_equal Hris::DevNameWhimsifier.whimsical_name("bob-002"),
                   reports_to["displayName"]
      refute_equal "Bob", reports_to["firstName"]
    end

    should "leave emails and non-name fields untouched" do
      result = Hris::DevNameWhimsifier.whimsify(build_attrs)

      assert_equal "alice@example.com", result[:email]
      assert_equal "Software Engineer", result[:job_title]
      assert_equal "alice@example.com", result[:hris_raw_data]["email"]
      assert_equal "bob@example.com", result[:hris_raw_data].dig("work", "reportsTo", "email")
    end

    should "not mutate the input attributes" do
      attrs = build_attrs
      Hris::DevNameWhimsifier.whimsify(attrs)

      assert_equal "Alice Smith", attrs[:name]
      assert_equal "Alice", attrs[:hris_raw_data]["firstName"]
      assert_equal "Bob Jones", attrs[:hris_raw_data].dig("work", "reportsTo", "displayName")
    end

    should "fall back to email as seed when external_id is missing" do
      attrs = build_attrs.merge(external_id: nil)
      result = Hris::DevNameWhimsifier.whimsify(attrs)

      assert_equal Hris::DevNameWhimsifier.whimsical_name("alice@example.com"), result[:name]
    end

    should "pass through untouched when no seed is available" do
      attrs = { name: "Alice Smith" }
      assert_equal attrs, Hris::DevNameWhimsifier.whimsify(attrs)
    end
  end

  context ".call" do
    should "pass through untouched outside development" do
      attrs = build_attrs
      assert_equal attrs, Hris::DevNameWhimsifier.call(attrs)
    end

    should "whimsify when enabled" do
      Hris::DevNameWhimsifier.stub(:enabled?, true) do
        result = Hris::DevNameWhimsifier.call(build_attrs)
        assert_equal Hris::DevNameWhimsifier.whimsical_name("bob-001"), result[:name]
      end
    end
  end
end
