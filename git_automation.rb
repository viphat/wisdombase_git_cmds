require 'thor'
require 'open3'
require 'date'

class GitAutomation < Thor
  PROJECT_PATH = '/Users/viphat/projects/sharewis/sharewis-act'
  JIRA_PREFIX_REGEX = /(SWWB|FDT)/
  JIRA_TICKET_REGEX = /(SWWB|FDT)-\d+/
  JIRA_TICKET_LINK = 'https://share-wis.atlassian.net/browse'
  JIRA_WISDOMBASE_RELEASE_LINK = 'https://share-wis.atlassian.net/projects/SWWB/versions/{{RELEASE_ID}}/tab/release-report-all-issues'

  desc "wisdombase_create_working_branch", "Automate creating a working branch for Wisdombase project."
  def wisdombase_create_working_branch
    branch_name = ask_branch_name
    merge_with = ask("Enter the branch to merge with (can be blank): ")

    commands = [
      "git checkout master",
      "git pull origin master",
      "git checkout -b #{branch_name}"
    ]

    merge_with = merge_with.strip
    commands << "git merge #{merge_with}" if merge_with != ''

    execute_in_project_dir(commands)
    puts "Done!"
  end

  desc "wisdombase_create_pull_request", "Automate creating a PR for Wisdombase project."
  def wisdombase_create_pull_request
    origin_branch_name = ask_branch_name
    merge_to = ask_choice("Merge to (D: develop, S: staging, M: master): ", ['d', 's', 'm'])
    pr_title = ask("Enter the PR title (Leave blank to use first commit message): ")
    draft = ask_yes_no("Create a draft PR? (Y/N): ")
    dry_run = ask_yes_no("Dry run? (Y/N): ")

    prefix = case merge_to
              when 'd'
                'dev'
              when 's'
                'stg'
              when 'm'
                ''
              end

    remote_base_branch = case merge_to
                          when 'd'
                            'develop'
                          when 's'
                            'staging'
                          when 'm'
                            'master'
                        end

    branch_name = origin_branch_name.strip
    branch_name = "#{prefix}/#{branch_name}" if prefix != ''

    jira_ticket = branch_name.match(JIRA_TICKET_REGEX)
    jira_ticket_link = jira_ticket ? "[#{jira_ticket}](#{JIRA_TICKET_LINK}/#{jira_ticket})" : ''

    if pr_title == ''
      Dir.chdir(PROJECT_PATH) do
        pr_title = `git checkout #{branch_name} && git log --no-merges --format=%B #{remote_base_branch}..#{branch_name} | head -n 1`.strip
      end
    end

    if pr_title !~ JIRA_PREFIX_REGEX
      branch_prefix = branch_name.match(JIRA_PREFIX_REGEX)
      pr_title = "#{branch_prefix}-#{pr_title}" if branch_prefix
    end

    commands = [
      "git checkout #{branch_name}",
      "git push origin #{branch_name}",
      "gh pr create --title '#{pr_title}' --body '#{jira_ticket_link}' --label '#{remote_base_branch}' --base '#{remote_base_branch}' --head #{branch_name} #{draft ? '--draft' : ''} #{dry_run ? '--dry-run' : ''}"
    ]

    commands << "git checkout #{origin_branch_name}"
    # commands << "gh pr view --json url --jq '.url'"
    execute_in_project_dir(commands)

    puts "Done!"
  end


  desc "wisdombase_git_workflow", "Automate git workflow for Wisdombase project."
  def wisdombase_git_workflow
    branch_name = ask_branch_name
    push_to = ask_choice("Push to (D: develop, S: staging, A: both staging and develop, M: master): ", ['d', 's', 'a', 'm'])
    with_force = ask_yes_no("Do you want to force push? (Y/N): ")
    delete_branch_if_exists = false

    delete_branch_if_exists = ask_yes_no("Delete branch if exists? (Y/N): ") unless push_to == 'm'

    sync_with_remote =
      if delete_branch_if_exists
        ask_yes_no("Sync with remote? (Y/N): ")
      else
        false
      end

    commands = [
      "git checkout #{branch_name}",
      "git push origin #{branch_name}#{with_force ? ' --force-with-lease' : ''}"
    ]

    if push_to == 'm'
      commands << "git checkout master"
      commands << "git pull origin master"
      commands << "git checkout #{branch_name}"
      commands << "git merge master --no-edit"
      commands << "git push origin #{branch_name}#{with_force ? ' --force-with-lease' : ''}"
    else
      create_branch_commands(commands, 'dev', 'develop', branch_name, delete_branch_if_exists, with_force, sync_with_remote) if ['d', 'a'].include?(push_to)
      create_branch_commands(commands, 'stg', 'staging', branch_name, delete_branch_if_exists, with_force, sync_with_remote) if ['s', 'a'].include?(push_to)
    end

    commands << "git checkout #{branch_name}"

    execute_in_project_dir(commands)
    puts "Done!"
  end

  desc "wisdombase_post_release", "Automate post-release process for Wisdombase project."
  def wisdombase_post_release
    commands = []

    branch_name = `git rev-parse --abbrev-ref HEAD`.strip

    # Check if there are any uncommitted changes
    uncommitted_changes = `git status --porcelain`.strip
    # check if there are untracked files
    untracked_files = `git ls-files --others --exclude-standard`.strip
    stash_changes = false

    if untracked_files != '' || uncommitted_changes != ''
      # Ask user if they want to stash the changes or commit themselves
      stash_changes = ask_yes_no("There are untracked files/uncommitted changes. Do you want to stash them? (Y/N): ")

      if stash_changes
        commands << "git add -A"
        commands << "git stash"
      else
        puts "Please commit or stash your changes first."
        exit 1
      end
    end

    commands += [
      "git checkout release",
      "git pull origin release",
      "git checkout master",
      "git pull origin master",
      "git merge release --no-edit",
      "git push origin master",
      "git checkout staging",
      "git pull origin staging",
      "git merge master --no-edit",
      "git push origin staging",
      "git checkout develop",
      "git pull origin develop",
      "git merge staging --no-edit",
      "git push origin develop",
      "git checkout stable",
      "git pull origin stable",
      "git checkout #{branch_name}"
    ]

    if stash_changes
      commands << "git stash pop"
    end

    execute_in_project_dir(commands)
    puts "Done!"
  end

  desc "wisdombase_create_release_pr", "Automate creating release PR for Wisdombase project."
  def wisdombase_create_release_pr
    jira_release_id = ask("Enter the Jira Release ID: ")
    pr_title = ask("Enter the PR title (Or leave it empty to use the automated generated title): ")

    if pr_title == ''
      today = Date.today
      pr_title = "Release Production - #{today.strftime('%Y-%m-%d')} - v#{jira_release_id}"
    end

    body_link = "[#{jira_release_id}](#{JIRA_WISDOMBASE_RELEASE_LINK.gsub('{{RELEASE_ID}}', jira_release_id)})"

    commands = [
      "gh pr create --title '#{pr_title}' --body 'Release Production - #{body_link}' --base 'release' --head 'master'"
    ]

    execute_in_project_dir(commands)

    puts "Done!"
  end

  desc "wisdombase_create_stable_release_pr", "Automate creating release branch for Wisdombase project (Stable Env)."
  def wisdombase_create_stable_release_pr
    jira_release_id = ask("Enter the Jira Release ID: ")
    stable_release_branch_name = ask("Enter the branch name to merge to stable (Or leave it empty to use the automated generated branch name): ")
    pr_title = ask("Enter the PR title (Or leave it empty to use the automated generated title): ")

    today = Date.today

    if pr_title == ''
      pr_title = "Release Stable - #{today.strftime('%Y-%m-%d')} - v#{jira_release_id}"
    end

    if stable_release_branch_name == ''
      stable_release_branch_name = "stable-#{today.strftime('%Y-%m-%d')}"
      puts "Stable Release Branch Name: #{stable_release_branch_name}"
      confirm = ask_yes_no("Please confirm the branch name is correct (Y/N): ")
      exit 1 unless confirm
    end

    body_link = "[#{jira_release_id}](#{JIRA_WISDOMBASE_RELEASE_LINK.gsub('{{RELEASE_ID}}', jira_release_id)})"

    commands = [
      "git push origin #{stable_release_branch_name}",
      "gh pr create --title '#{pr_title}' --body 'Release Stable - #{body_link}' --base 'stable' --head '#{stable_release_branch_name}'"
    ]

    execute_in_project_dir(commands)
    puts "Done!"
  end

  no_commands do
    def execute_in_project_dir(commands)
      Dir.chdir(PROJECT_PATH) do
        execute_commands(commands)
      end
    end

    def ask_branch_name
      branch_name = ''

      branch_name = ask("Enter the branch name (Leave empty to get current branch): ")

      # Get current branch
      if branch_name == ''
        branch_name = `git rev-parse --abbrev-ref HEAD`.strip
      end

      branch_name
    end

    def ask_yes_no(question)
      answer = nil
      until !answer.nil? &&  ['y', 'n', ''].include?(answer.downcase)
        answer = ask(question)
      end
      answer.downcase == 'y' && !answer.empty?
    end

    def ask_choice(question, choices)
      answer = ''
      until choices.include?(answer.downcase)
        answer = ask(question)
      end
      answer.downcase
    end

    def create_branch_commands(commands, prefix, remote_base_branch, branch_name, delete_branch_if_exists, with_force, sync_with_remote)
      commands << "git checkout #{remote_base_branch}"
      commands << "git pull origin #{remote_base_branch}"

      branch_exists = `git branch --list #{prefix}/#{branch_name}`.strip

      if branch_exists != ''
        if delete_branch_if_exists
          commands << "git branch --list #{prefix}/#{branch_name} && git branch -D #{prefix}/#{branch_name} || echo 'Branch not found, nothing to delete'"
          commands << "git checkout -b #{prefix}/#{branch_name}"
        else
          commands << "git checkout #{prefix}/#{branch_name}"
          commands << "git merge #{remote_base_branch} --no-edit" if sync_with_remote
        end
      else
        commands << "git checkout -b #{prefix}/#{branch_name}"
      end

      commands << "git merge #{branch_name} --no-edit"
      commands << "git push origin #{prefix}/#{branch_name}#{with_force ? ' --force-with-lease' : ''}"
    end

    def execute_commands(commands)
      commands.each do |command|
        puts "Executing: #{command}"
        stdout, stderr, status = Open3.capture3(command)

        if status.success?
          puts stdout
        else
          STDERR.puts "Command failed: #{command}"
          STDERR.puts stderr
          exit 1
        end
      end
    end
  end
end

GitAutomation.start(ARGV)