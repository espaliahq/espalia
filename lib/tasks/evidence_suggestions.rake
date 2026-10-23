# frozen_string_literal: true

namespace :evidence do
  namespace :suggestions do
    desc "Ask for placement suggestions on self feedback that has none. A dry run by default; CONFIRM=1 enqueues " \
         "one model call per item, PER_MINUTE (default 20) a minute. " \
         "TENANT=<slug> narrows it to one workspace."
    task backfill_self: :environment do
      backfill = Evidence::SelfFeedbackBackfill.new(
        tenant_slug: ENV["TENANT"],
        per_minute: ENV.fetch("PER_MINUTE", Evidence::SelfFeedbackBackfill::DEFAULT_PER_MINUTE)
      )
      backfill.candidates.each { |tenant, ids| puts "  #{tenant.slug}: #{ids.size}" }
      skipped = backfill.skipped_tenants.map(&:slug)
      puts "  Skipped, suggestions off or no model: #{skipped.join(', ')}" if skipped.any?

      if ENV["CONFIRM"] == "1"
        enqueued = backfill.enqueue!
        puts "Enqueued #{enqueued} suggestion runs for self feedback, #{backfill.per_minute} a minute, " \
             "one model call each. The last is due in about #{(enqueued.to_f / backfill.per_minute).ceil} minutes."
      else
        puts "Dry run: #{backfill.count} self feedback items would get suggestions, one model call each, " \
             "#{backfill.per_minute} a minute over about #{backfill.minutes} minutes. Run again with CONFIRM=1 to enqueue."
      end
    end

    desc "Score placement suggestions against the hand-placed fixtures, through a tenant's configured model " \
         "(evidence:suggestions:eval[slug], MODEL=… to try another id; SUGGESTION_MODEL=baseline needs no tenant). Not run in CI."
    task :eval, [ :tenant ] => :environment do |_task, args|
      require_relative "evidence_suggestions_eval"

      model =
        if ENV["SUGGESTION_MODEL"] == "baseline"
          EvidenceSuggestionsEval::BaselineModel.new
        else
          begin
            EvidenceSuggestionsEval.model_for(slug: args[:tenant].presence || ENV["TENANT"], model: ENV["MODEL"])
          rescue ArgumentError => e
            abort e.message
          end
        end

      report = EvidenceSuggestionsEval.new(model: model).run
      percent = ->(value) { value.nil? ? "n/a" : "#{(value * 100).round(1)}%" }
      puts "Prompt #{report[:prompt_version]} · #{report[:provider]} #{report[:model]} · #{report[:items]} items " \
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
