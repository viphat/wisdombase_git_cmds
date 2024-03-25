require 'thor'
require 'open3'

class GitAutomation < Thor
  PROJECT_PATH = '/Users/viphat/projects/sharewis/sharewis-act'
  JIRA_PREFIX_REGEX = /(SWWB|FDT)/
  JIRA_TICKET_REGEX = /(SWWB|FDT)-\d+/
  JIRA_TICKET_LINK = 'https://share-wis.atlassian.net/browse'

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
    branch_name = ask_branch_name
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

    branch_name = branch_name.strip
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

    # commands << "gh pr view --json url --jq '.url'"
    execute_in_project_dir(commands)

    puts "Done!"
  end


  desc "wisdombase_git_workflow", "Automate git workflow for Wisdombase project."
  def wisdombase_git_workflow
    branch_name = ask_branch_name
    with_force = ask_yes_no("Do you want to force push? (Y/N): ")
    push_to = ask_choice("Push to (D: develop, S: staging, A: both): ", ['d', 's', 'a'])
    delete_branch_if_exists = ask_yes_no("Delete branch if exists? (Y/N): ")

    commands = [
      "git checkout #{branch_name}",
      "git push origin #{branch_name}#{with_force ? ' --force-with-lease' : ''}"
    ]

    add_branch_commands(commands, 'dev', 'develop', branch_name, delete_branch_if_exists, with_force) if ['d', 'a'].include?(push_to)
    add_branch_commands(commands, 'stg', 'staging', branch_name, delete_branch_if_exists, with_force) if ['s', 'a'].include?(push_to)

    commands << "git checkout #{branch_name}"

    execute_in_project_dir(commands)
    puts "Done!"
  end

  desc "wisdombase_post_release", "Automate post-release process for Wisdombase project."
  def wisdombase_post_release
    commands = [
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
      ask("Enter the branch name: ")
    end

    def ask_yes_no(question)
      answer = ''
      until ['y', 'n'].include?(answer.downcase)
        answer = ask(question)
      end
      answer.downcase == 'y'
    end

    def ask_choice(question, choices)
      answer = ''
      until choices.include?(answer.downcase)
        answer = ask(question)
      end
      answer.downcase
    end

    def add_branch_commands(commands, prefix, remote_base_branch, branch_name, delete_branch_if_exists, with_force)
      commands << "git checkout #{remote_base_branch}"
      commands << "git pull origin #{remote_base_branch}"

      branch_exists = `git branch --list #{prefix}/#{branch_name}`.strip

      if branch_exists != ''
        if delete_branch_if_exists
          commands << "git branch --list #{prefix}/#{branch_name} && git branch -D #{prefix}/#{branch_name} || echo 'Branch not found, nothing to delete'"
          commands << "git checkout -b #{prefix}/#{branch_name}"
        else
          commands << "git checkout #{prefix}/#{branch_name}"
          commands << "git merge #{remote_base_branch} --no-edit"
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