require "json"
require "socket"
require "file_utils"
require "option_parser"

require "./assist_ant/paths"
require "./assist_ant/event_publisher"
require "./assist_ant/hooks_manager"
require "./assist_ant/commands/ping"
require "./assist_ant/commands/calendar_item"
require "./assist_ant/commands/actionable_item"
require "./assist_ant/commands/task"
require "./assist_ant/commands/briefing"
require "./assist_ant/commands/session_event"
require "./assist_ant/commands/install_hooks"
require "./assist_ant/cli"

# Skip auto-invocation when required from specs.
unless ENV.has_key?("ASSIST_ANT_SKIP_CLI")
  AssistAnt::CLI.run(ARGV)
end
