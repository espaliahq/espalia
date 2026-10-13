# frozen_string_literal: true

require "test_helper"

# Pins the guards on the workflow that merges Dependabot's PRs unreviewed.
# A broken guard here fails open, so CI is the only place anyone would notice.
class CiWorkflowTest < ActiveSupport::TestCase
  WORKFLOWS = Rails.root.glob(".github/workflows/*.{yml,yaml}").freeze
  AUTO_MERGE_JOB = "dependabot-auto-merge"

  def ci_jobs = YAML.load_file(Rails.root.join(".github/workflows/ci.yml")).fetch("jobs")

  context "the Dependabot auto-merge job" do
    should "wait for every other CI job" do
      others = ci_jobs.keys - [ AUTO_MERGE_JOB ]

      assert_equal others.sort, ci_jobs.dig(AUTO_MERGE_JOB, "needs").sort,
        "#{AUTO_MERGE_JOB} must list every CI job under needs:, or Dependabot PRs merge without it"
    end

    should "trust the PR author and repository, never the actor" do
      expected = "github.event_name == 'pull_request' && " \
                 "github.event.pull_request.user.login == 'dependabot[bot]' && " \
                 "github.event.pull_request.head.repo.full_name == github.repository"

      assert_equal expected, ci_jobs.dig(AUTO_MERGE_JOB, "if").squish
    end

    should "act only once every commit is Dependabot's, signed" do
      steps = ci_jobs.dig(AUTO_MERGE_JOB, "steps")
      check, *actions = steps

      assert_equal "commits", check["id"]
      assert_includes check["run"], '.author.login != "dependabot[bot]" or .commit.verification.verified != true'
      actions.each { |step| assert_equal "steps.commits.outputs.trusted == 'true'", step["if"], step["name"] }
    end

    should "merge only the head CI tested" do
      script = ci_jobs.dig(AUTO_MERGE_JOB, "steps").pluck("run").join("\n")

      assert_includes script, '--match-head-commit "$HEAD_SHA"'
    end
  end

  context "every workflow" do
    should "keep expressions out of shell scripts" do
      offenders = WORKFLOWS.flat_map do |path|
        YAML.load_file(path).fetch("jobs").flat_map do |name, job|
          Array(job["steps"]).filter_map do |step|
            "#{path.basename} › #{name} › #{step['name']}" if step["run"].to_s.include?("${{")
          end
        end
      end

      assert_empty offenders, "pass values through env: and quote \"$VAR\"; ${{ }} in run: is shell injection"
    end

    should "avoid triggers that run with write access on untrusted input" do
      triggers = WORKFLOWS.to_h do |path|
        # YAML 1.1 reads a bare `on` key as the boolean true; a quoted one stays a string.
        doc = YAML.load_file(path)
        on = doc.fetch(true) { doc.fetch("on") }
        [ path.basename.to_s, on.is_a?(Hash) ? on.keys : Array(on) ]
      end

      triggers.each { |file, names| assert_not_empty names, "#{file} declares no triggers" }
      assert_empty triggers.values.flatten & %w[workflow_run pull_request_target issue_comment]
    end
  end
end
