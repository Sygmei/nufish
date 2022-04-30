# TODO: fix single arg
let template_file = "set singlearg '^\\S+\\$'
function __fishx_is_full_subcommand
    set -l cmd (commandline -poc)
    set -e cmd[1]
    set i 1
    for cmdpart in $cmd
        if string match -q -- "-*" $cmdpart
            set -e cmd[$i]
        end
        set i (math $i + 1)
    end
    set cmd_dotted (string join -- '->>' $cmd)
    set match_cmd "$argv\\$"
    if string match -rq $match_cmd $cmd_dotted
        return 0
    end
    return 1
end

################
# Call wrapper #
################
function {function_name}
    nu -c \"source ~/.config/nushell/config.nu; {function_name} $argv\"
end

############################
# Command tree completions #
############################
{command_tree_completions}

##########################
# Parameters completions #
##########################
{completions}
"

def get_base_command [command: table] {
    $command.command | split row " " | get 0
}

def match [input, matchers: record] {
    echo $matchers | get $input | do $in
}

def get_subcommands_chain_combination [command: table] {
    $command.command
    | split row " "
    | collect { |command|
        2..($command | length)
        | each { |i| $command |
            range 1..($i - 1)
        }
    }
}

def get_subcommands_chain_path [command: table] {
    $command.command | split row " " | range 1.. | str collect "->>"
}

def make_subcommand_filter [subcommand_path: string] {
    $' -n "__fishx_is_full_subcommand §§($subcommand_path)§§"' | str replace -a "§§" "'"
}

def "nuwrap generate positional" [command: table, argument: table, argument_index: int] {
    let description = if not ($argument.description | empty?) {
        $' -d "($argument.parameter_name): ($argument.description)"'
    } else {
        $' -d "($argument.parameter_name)"'
    }
    let base_command = get_base_command $command
    let subcommand_path = get_subcommands_chain_path $command
    let subcommand_filter = if (($command.command | str contains " ") || ($argument_index > 0)) {
        if $argument_index > 0 {
            let arg_index_min_1 = ($argument_index - 1)
            let pos_arg_path = ((..$arg_index_min_1) | each { |it| "$singlearg" } | str collect "->>")
            let subcommand_path_separator = if not ($subcommand_path | empty?) { "->>"} else { "" }
            make_subcommand_filter ($"($subcommand_path)($subcommand_path_separator)($pos_arg_path)")
        } else {
            make_subcommand_filter $subcommand_path
        }
    } else {
        ' -n "__fish_use_subcommand"'
    }
    $'complete -c "($base_command)"($subcommand_filter)($description) -xk'
}

# TODO: take positional into account for subcommand_filter (otherwise flags wont show up)
def "nuwrap generate flag" [command: table, flag: table] {
    let description = if not ($flag.description | empty?) { $' -d "($flag.description)"'}
    let base_command = get_base_command $command
    let subcommand_path = get_subcommands_chain_path $command
    let subcommand_filter = if ($command.command | str contains " ") {
        make_subcommand_filter $subcommand_path
    } else {
        ' -n "__fish_use_subcommand"'
    }
    let base = $'complete -c "($base_command)"($subcommand_filter)($description) -k'
    let short_flag = (if not ($flag.short_flag | empty?) { $' -s "($flag.short_flag)"' })
    let long_flag = ($' -l "($flag.parameter_name | str trim -r -c "?")"')
    let flag_base = $'($base)($short_flag)($long_flag)'
    match $flag.parameter_type {
        named: {
            let ispath = (if ($flag.syntax_shape != "path") { " -f" } else { " -F" })
            $'($flag_base)($ispath) -r'
        },
        switch: {
            $flag_base
        },
        rest: {
            "# rest"
        }
    }
}

def "nuwrap generate command" [command: table] {
    let description = ($'-d "($command.description)" ')
    let base_command = get_base_command $command
    let subcommand_path = (get_subcommands_chain $command | str collect "->>")
    let subcommand_filter = if ($command.command | str contains " ") {
        $'-n "__fishx_is_full_subcommand \'($subcommand_path)\'"'
    } else {
        '-n "__fish_use_subcommand"'
    }
    let base = $'complete -c "($base_command)" ($subcommand_filter) -d "($description)" -f -ka "$()"'
    $base
}

def "nuwrap generate completions" [command: table] {
    let positional_completions = ($command.signature | where parameter_type == "positional" | each -n { | arg |
        nuwrap generate positional $command $arg.item $arg.index
    })
    let flag_completions = ($command.signature | where parameter_type != "positional" | each { | flag |
        nuwrap generate flag $command $flag
    })
    let command_completions = (append $positional_completions | append $flag_completions | reduce { |l1, l2|
        $"($l1)\n($l2)"
    })
    $"# ($command.command) completions\n($command_completions)"
}

def nuwrap [--command_name (-c): string] {
    echo $"Wrapping command <($command_name)> to fish shell"
    let root_command = ($nu.scope.commands | where command == $command_name && is_sub == false)
    if ($root_command | empty?) {
        error make {msg: $"Command <($command_name)> not found"}
    }
    let subcommands = ($nu.scope.commands | where command =^ $"($command_name) " && is_sub == true)
    let all_commands = ($subcommands | append $root_command)

    let commands_chains = ($subcommands | each { |it | get_subcommands_chain_combination $it } | flatten | uniq)

    let completions = ($all_commands | each { |current_command|
        nuwrap generate completions $current_command
    } | reduce { |l1, l2|
        $"($l1)\n\n($l2)"
    })

    let command_tree_completions = ($commands_chains | each { | it |
        let full_command_name = ($it | insert 0 $command_name | str collect " ")
        let command_description = ($nu.scope.commands | where command == $full_command_name | get usage.0)
        let terminal_command = ($it | last)
        if ($it | length) > 1 {
            let subcommand_path = ($it | range ..-2 | str collect "->>")
            $'complete -c "($command_name)"(make_subcommand_filter $subcommand_path) -f -ka "($terminal_command)" -d "($command_description)"'
        } else {
            $'complete -c "($command_name)" -n "__fish_use_subcommand" -f -ka "($terminal_command)" -d "($command_description)"'
        }
    } | reduce { |l1, l2|
        $"($l1)\n($l2)"
    })
    let output_file = $"/home/(whoami | str trim)/.config/fish/functions/($command_name).fish"
    echo $"Saved wrapper to ($output_file)"
    {function_name: $command_name, command_tree_completions: $command_tree_completions, completions: $completions} | format $template_file | save $output_file
}
