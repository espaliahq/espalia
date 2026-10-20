# frozen_string_literal: true

require "test_helper"

class Ai::NamePseudonymiserTest < ActiveSupport::TestCase
  PEOPLE = [
    [ "01", "Alex Chen" ],
    [ "02", "Anna Reid" ],
    [ "03", "Annabel Park" ],
    [ "04", "Alexander Stone" ],
    [ "05", "Sam Lee" ],
    [ "06", "Sam Wu" ]
  ].freeze

  def pseudonymiser(people = PEOPLE) = Ai::NamePseudonymiser.new(people)

  context "#pseudonymise" do
    should "replace a full name and a first name only one person has, case-insensitively" do
      text = pseudonymiser.pseudonymise("alex chen shipped it, and Alex kept ALEX CHEN's team informed.")

      assert_equal "Person 1 shipped it, and Person 1 kept Person 1's team informed.", text
    end

    should "use the same placeholder for the same person on every request" do
      assert_equal pseudonymiser.pseudonymise("Anna Reid"), pseudonymiser.pseudonymise("Anna Reid")
      assert_equal "Person 2", pseudonymiser.pseudonymise("Anna")
    end

    should "match whole words, so a name inside another name is left alone" do
      text = pseudonymiser.pseudonymise("Annabel and Anna met Alexander and Alex, not Annas or Alexa.")

      assert_equal "Person 3 and Person 2 met Person 4 and Person 1, not Annas or Alexa.", text
    end

    should "take the longest name first when one name starts another" do
      assert_equal "Person 1 and Person 2", pseudonymiser.pseudonymise("Alex Chen and Anna Reid")
      people = [ [ "01", "Alex" ], [ "02", "Alex Chen" ] ]
      # "Alex" is one person's whole name and another's first name, so it cannot stand for either alone.
      assert_equal "Person 2 and Person 3", pseudonymiser(people).pseudonymise("Alex Chen and Alex")
    end

    should "give a first name two people share a placeholder of its own" do
      text = pseudonymiser.pseudonymise("Sam Lee and Sam Wu both said Sam was right.")

      assert_match(/\APerson 5 and Person 6 both said Person (\d+) was right\.\z/, text)
      shared = text[/Person (\d+) was right/, 1].to_i
      assert_operator shared, :>, PEOPLE.size
    end

    should "tolerate extra whitespace inside a name and punctuation around it" do
      assert_equal "(Person 1), thanks!", pseudonymiser.pseudonymise("(Alex   Chen), thanks!")
    end

    should "handle names with apostrophes, hyphens and accents" do
      people = [ [ "01", "Siobhán O'Brien-Lee" ], [ "02", "Zoë Ångström" ] ]
      text = pseudonymiser(people).pseudonymise("Siobhán O'Brien-Lee thanked zoë, and Ångström too.")

      assert_equal "Person 1 thanked Person 2, and Ångström too.", text
    end

    should "leave text with no names, blank text and a tenant with no people alone" do
      assert_equal "Nobody here.", pseudonymiser.pseudonymise("Nobody here.")
      assert_nil pseudonymiser.pseudonymise(nil)
      assert_equal "Alex Chen", pseudonymiser([]).pseudonymise("Alex Chen")
    end

    should "ignore blank names and one-letter first names" do
      people = [ [ "01", "" ], [ "02", "J Smith" ] ]

      assert_equal "J met Person 2.", pseudonymiser(people).pseudonymise("J met J Smith.")
    end
  end

  context "first names that are ordinary words" do
    should "be left alone on request, while full names still go" do
      people = [ [ "01", "Will Hart" ], [ "02", "Grace Ng" ] ]
      names = pseudonymiser(people)
      text = "Will Hart will show the grace period to Grace Ng."

      assert_equal "Person 1 will show the grace period to Person 2.", names.pseudonymise(text, first_names: false)
      assert_equal "Person 1 Person 1 show the Person 2 period to Person 2.", names.pseudonymise(text)
    end

    should "treat a one-word name as a full name even when first names are left alone" do
      assert_equal "Person 1 helped", pseudonymiser([ [ "01", "Madonna" ] ]).pseudonymise("Madonna helped", first_names: false)
    end
  end

  should "stay fast with thousands of people, compiling only names whose first word is in the text" do
    people = Array.new(5_000) { |i| [ format("%08d", i), "Given#{i} Family#{i}" ] } + [ [ "99999999", "Alex Chen" ] ]
    names = pseudonymiser(people)
    text = ("The quarter went well. " * 400) + "Alex Chen led it."

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = names.pseudonymise(text)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_match(/Person 5001 led it\.\z/, result)
    assert_operator elapsed, :<, 0.5
  end

  context "#restore" do
    should "put names back in what came back" do
      names = pseudonymiser
      names.pseudonymise("Alex Chen led the outage review with Anna.")

      assert_equal "“Alex Chen led” shows ownership; Anna agreed.", names.restore("“Person 1 led” shows ownership; Person 2 agreed.")
    end

    should "restore the longest form the request used, as typed" do
      names = pseudonymiser
      names.pseudonymise("alex helped. Later Alex Chen presented.")

      assert_equal "Alex Chen helped.", names.restore("Person 1 helped.")
    end

    should "restore a possessive" do
      names = pseudonymiser
      names.pseudonymise("Anna Reid")

      assert_equal "Anna Reid's plan", names.restore("Person 2's plan")
    end

    should "leave a placeholder it did not issue alone" do
      names = pseudonymiser
      names.pseudonymise("Alex Chen")

      assert_equal "Person 9 and Alex Chen", names.restore("Person 9 and Person 1")
    end

    should "leave a placeholder that was already in the text alone when no name was swapped" do
      names = pseudonymiser
      names.pseudonymise("Person 3 wrote this.")

      assert_equal "Person 3 wrote this.", names.restore("Person 3 wrote this.")
    end

    should "round trip text containing every name" do
      names = pseudonymiser
      original = "Alex Chen, Anna Reid, Annabel Park, Alexander Stone, Sam Lee and Sam Wu all agreed."

      assert_equal original, names.restore(names.pseudonymise(original))
    end

    should "pass blank text through" do
      assert_nil pseudonymiser.restore(nil)
      assert_equal "", pseudonymiser.restore("")
    end
  end

  context ".for" do
    should "read the tenant's people and nobody else's" do
      tenant = create(:tenant)
      other = create(:tenant)
      ActsAsTenant.with_tenant(tenant) { create(:person, tenant: tenant, name: "Alex Chen") }
      ActsAsTenant.with_tenant(other) { create(:person, tenant: other, name: "Morgan Reid") }

      text = Ai::NamePseudonymiser.for(tenant).pseudonymise("Alex Chen thanked Morgan Reid.")

      assert_equal "Person 1 thanked Morgan Reid.", text
    end
  end
end
