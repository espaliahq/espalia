# frozen_string_literal: true

namespace :evidence do
  namespace :suggestions do
    desc "Score placement suggestions against the hand-placed fixtures (MODEL=…, SUGGESTION_MODEL=baseline). Not run in CI."
    task eval: :environment do
      require_relative "evidence_suggestions_eval"

      model =
        if ENV["SUGGESTION_MODEL"] == "baseline"
          EvidenceSuggestionsEval::BaselineModel.new
        else
          abort "No Anthropic API key in credentials (anthropic.api_key); try SUGGESTION_MODEL=baseline" unless Evidence::SuggestionModel.configured?
          Evidence::SuggestionModel.new(model: ENV.fetch("MODEL", Evidence::SuggestionModel::DEFAULT_MODEL))
        end

      report = EvidenceSuggestionsEval.new(model: model).run
      percent = ->(value) { value.nil? ? "n/a" : "#{(value * 100).round(1)}%" }
      puts "Prompt #{report[:prompt_version]} · model #{report[:model]} · #{report[:items]} items " \
           "(#{report[:placeable]} placeable, #{report[:uncovered]} the framework doesn't cover)"
      puts "  Cell match, top suggestion:  #{percent.(report[:cell_match_top])}"
      puts "  Cell match, any suggestion:  #{percent.(report[:cell_match_any])}"
      puts "  Valence match on hit cells:  #{percent.(report[:valence_match])}"
      puts "  Precision of all suggestions: #{percent.(report[:precision])}"
      puts "  Uncovered items left empty:  #{percent.(report[:uncovered_left_empty])}"
      report[:rows].each do |row|
        puts "    #{row[:id]}: #{row[:hit] ? 'hit ' : 'miss'} (#{row[:proposed]} proposed#{', not covered' if row[:uncovered]})"
      end
    end
  end
end
