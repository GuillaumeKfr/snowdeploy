#! /bin/bash

source "$PROG_DIR/logging.sh"

# Check that required dependencies are installed
# Return codes:
#   0 if all deps are present
#   1 if snowsql is missing
#   2 if sqlite3 is missing
#   3 if both are missing
__check_deps() {
    local result=0

    if [[ ! "$(command -v snowsql)" ]]; then
        logging::error "Missing snowsql dependency - visit https://docs.snowflake.com/en/user-guide/snowsql-install-config.html for more information"
        result+=1
    fi

    if [[ ! "$(command -v sqlite3)" ]]; then
        logging::error "Missing sqlite3 dependency - visit https://www.sqlite.org/index.html for more information"
        result+=2
    fi

    return $result
}

# Get db name from git repo name
# Output:
#   Write db name to stdout
__get_repo_name() {
    basename "$(git rev-parse --show-toplevel)"
}

# Get env name from current active git branch
# Output:
#   Write env name to stdout
__get_curr_branch_name() {
    local git_branch

    git_branch=$(git symbolic-ref --short HEAD)
    echo "$git_branch" | tr '[:upper:]' '[:lower:]'
}

# Ask the user to select one of the dir in the dir passed as parameter
# Arguments:
#   1   Path of the dir to search
# Output:
#   Write the selected dir to stdout
__select_subdir() {
    local search_dir=$1

    select version in $(find "$search_dir"/* -maxdepth 0 -type d -printf '%f\n'); do
        echo "$version"
        break
    done
}

# Replace the placeholders (format: ${placeholder}) in a file with a value
# Arguments:
#   1   Path of the file to edit
#   2   Name of the placeholder
#   3   Value to use as replacement
__replace_placeholder() {
    local file=$1
    local env=$2

    local placeholder
    local value
    
    if [[ ! -f $file ]]; then
        logging::error "Trying to update non-existing file:  $file"
    fi

    while read line; do
        placeholder=$(echo $line | cut -d "=" -f 1)
        value=$(echo $line | cut -d "=" -f 2)

        sed -i "s,\${$placeholder},${value},g" "$file"
    done < "$env".env
}
