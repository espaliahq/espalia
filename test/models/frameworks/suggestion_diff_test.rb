# frozen_string_literal: true

require "test_helper"

class Frameworks::SuggestionDiffTest < ActiveSupport::TestCase
  context ".call" do
    context "when strings are identical" do
      should "return a single equal segment" do
        result = Frameworks::SuggestionDiff.call(original: "Hello", proposed: "Hello")

        assert_equal [ { kind: :equal, text: "Hello" } ], result
      end
    end

    context "simple deletions" do
      should "strikethrough only the removed suffix" do
        result = Frameworks::SuggestionDiff.call(
          original: "Provides feedbacks", proposed: "Provide feedback"
        )

        assert_equal [
          { kind: :equal,   text: "Provide" },
          { kind: :removed, text: "s" },
          { kind: :equal,   text: " feedback" },
          { kind: :removed, text: "s" }
        ], result
      end

      should "strikethrough a whole removed prefix" do
        result = Frameworks::SuggestionDiff.call(
          original: "very quickly", proposed: "quickly"
        )

        assert_equal [
          { kind: :removed, text: "very " },
          { kind: :equal,   text: "quickly" }
        ], result
      end
    end

    context "simple additions" do
      should "mark only the added suffix" do
        result = Frameworks::SuggestionDiff.call(
          original: "Focus", proposed: "Focussed"
        )

        assert_equal [
          { kind: :equal, text: "Focus" },
          { kind: :added, text: "sed" }
        ], result
      end

      should "mark a single-character insertion inline" do
        result = Frameworks::SuggestionDiff.call(
          original: "color", proposed: "colour"
        )

        assert_equal [
          { kind: :equal, text: "colo" },
          { kind: :added, text: "u" },
          { kind: :equal, text: "r" }
        ], result
      end
    end

    context "substitutions" do
      should "render a replacement as adjacent remove + add" do
        result = Frameworks::SuggestionDiff.call(
          original: "cat sat", proposed: "dog sat"
        )

        assert_equal [
          { kind: :removed, text: "cat" },
          { kind: :added,   text: "dog" },
          { kind: :equal,   text: " sat" }
        ], result
      end
    end

    context "whitespace-only changes" do
      should "collapse trailing-space trim to equal-only" do
        result = Frameworks::SuggestionDiff.call(
          original: "Hello ", proposed: "Hello"
        )

        assert_equal [ { kind: :equal, text: "Hello" } ], result
      end

      should "collapse double-space reduction to equal-only" do
        result = Frameworks::SuggestionDiff.call(
          original: "Hello  world", proposed: "Hello world"
        )

        assert_equal [ { kind: :equal, text: "Hello world" } ], result
      end
    end

    context "density threshold" do
      should "render interleaved when there are exactly 3 change runs" do
        # "a b c d" -> "x b y d" is: !a !b b !c !d b d — produce 2 swaps around equals.
        # Build one with exactly 3 runs deterministically: add three distinct chars.
        result = Frameworks::SuggestionDiff.call(
          original: "abcdef", proposed: "aXbcYdeZf"
        )

        refute_equal :fallback, result
        runs = result.count { |seg| seg[:kind] != :equal }
        assert_equal 3, runs
      end

      should "fall back when there are more than 3 change runs" do
        result = Frameworks::SuggestionDiff.call(
          original: "abcdef", proposed: "WaXbcYdeZfQ"
        )

        assert_equal :fallback, result
      end

      should "fall back on complete replacement of unrelated phrases" do
        # "a b c d" -> "w x y z" yields alternating swap runs well over 3.
        result = Frameworks::SuggestionDiff.call(
          original: "a b c d", proposed: "w x y z"
        )

        assert_equal :fallback, result
      end
    end

    context "grapheme handling" do
      should "treat a combining accent as one grapheme" do
        # "e" + combining acute accent vs. plain "e" — 1 grapheme diff, not 2.
        original = "cafe"
        proposed = "café" # café with precomposed é

        result = Frameworks::SuggestionDiff.call(original: original, proposed: proposed)

        assert_equal [
          { kind: :equal,   text: "caf" },
          { kind: :removed, text: "e" },
          { kind: :added,   text: "é" }
        ], result
      end

      should "treat a multi-codepoint emoji as a single grapheme" do
        # 👩‍🔬 (woman scientist) is a ZWJ sequence — one grapheme cluster.
        result = Frameworks::SuggestionDiff.call(
          original: "hi", proposed: "hi \u{1F469}‍\u{1F52C}"
        )

        refute_equal :fallback, result
        added = result.find { |seg| seg[:kind] == :added }
        assert_equal " \u{1F469}‍\u{1F52C}", added[:text]
      end
    end

    context "empty / blank inputs" do
      should "treat nil proposed as an empty string" do
        result = Frameworks::SuggestionDiff.call(original: "Hello", proposed: nil)

        assert_equal [ { kind: :removed, text: "Hello" } ], result
      end

      should "treat nil original as an insertion" do
        result = Frameworks::SuggestionDiff.call(original: nil, proposed: "Hello")

        assert_equal [ { kind: :added, text: "Hello" } ], result
      end

      should "return equal-only for two blank strings" do
        result = Frameworks::SuggestionDiff.call(original: "", proposed: "")

        assert_equal [ { kind: :equal, text: "" } ], result
      end
    end
  end
end
