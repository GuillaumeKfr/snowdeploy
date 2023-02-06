#! /bin/bash

#/ Prepare and deploy version scripts for Snowflake.
#/
#/ Syntax: deploy.sh action [-e env] [-v] [-y] [-h]
#/
#/ Parameters:
#/   action  Action to perform. Possible values:
#/             init: Setup the deployment structures in Snowflake
#/             prep[are]: Prepare the scripts files for a given version
#/             [prepare_]diff: Prepare the scripts files based on last saved state
#/             exec[ute]: Run the prepared scripts
#/             clean: Remove deploy folder and logs
#/
#/ Options:
#/   e  Target deployment env (dev/uat/prod). Defaults to current git branch.
#/   v  Version to be deployed. Can be selected at runtime.
#/   y  Do not ask for confirmation before deploying.
#/   h  Display this help.
#/
#/ External dependencies:
#/   SnowSQL
#/   SQLite3

set -o errexit  # abort on nonzero exitstatus
set -o nounset  # abort on unbound variable
set -o pipefail # don't hide errors within pipes
# set -x

PROG_NAME=$(basename "$0")
PROG_DIR=$(readlink -m "$(dirname "$0")")
readonly PROG_NAME PROG_DIR

source "$PROG_DIR/helpers.sh"

# Print on STDOUT the usage message based on the header comment in the script
# The comment should start with #/ followed by either a newline or a space
usage() {
    grep '^#/' "$PROG_DIR/$PROG_NAME" | sed 's/^#\/\($\| \)//'
    exit
}

# Initialize sqlite state database
init() {
    local query

    mkdir -p "$(dirname "$state_file")"

    query="create table if not exists tech.deploy_state (
            filekey     varchar(255)
            , hash      varchar(32)
            , run_time  timestamp
            , status    varchar(32)
            , primary key (filekey, run_time)
        );"

    if snowsql -c "${db}_${env}" -o exit_on_error=true -o friendly=false -o quiet=true -q "$query"; then
        logging::success "Database initialized"
    else
        logging::die "Failed to initialize"
    fi
}

__cleanup() {
    rm -rf "$tmp_dir "
}

# Build the global deployment file, referring each individual sql script
__build_global_file() {
    local file

    rm -f "$global_version_file"

    logging::info "Building global script"

    for file in "$deploy_dir"/*.sql "$deploy_dir"/**/*.sql; do
        if [[ -f $file ]]; then
            echo "!source $file" >>"$global_version_file"
        fi
    done

    echo "!quit" >>"$global_version_file"
}

# Execute the global deployment file with snowsql
__execute_global_file() {
    local log_file choice

    log_file="${PROG_DIR}/deploy_$(date "+%Y%m%d_%H%M%S").log"

    if [[ $ask_for_confirmation == true ]]; then
        read -p "$global_version_file will be executed in $env. Continue (y/n)? " -n 1 -r choice
        echo

        case "$choice" in
            y | Y) logging::info "Executing script" ;;
            n | N)
                logging::info "Stopping deployment"
                exit 1
                ;;
            *) logging::die "Invalid choice" ;;
        esac
    fi

    if snowsql -c "${db}_${env}" -o exit_on_error=true -f "$global_version_file" | tee "$log_file"; then
        return 0
    else
        return 1
    fi
}

__retrieve_stored_state() {
    logging::info "Retrieving current state"

    query="select
            array_agg(object_construct(*))
            from
            (
                select *
                from tech.deploy_state
                qualify rank() over (partition by filekey order by run_time desc) = 1
            );
    "

    snowsql -c "${db}_${env}" \
        -o exit_on_error=true \
        -o friendly=false \
        -o quiet=true \
        -q "$query" \
        -o header=false \
        -o output_format=plain \
        -o output_file="$state_file"
}

__get_stored_state() {
    jq -r --arg KEY "$1" '.[] | select(.FILEKEY==$KEY) | .HASH' "$state_file"
}

# Maintain the hash of executed files in the state db
__maintain_state() {
    local file query update_file

    logging::info "Maintaining new state into database"
    
    update_file="$tmp_dir/update_state.sql"
    
    for file in "$deploy_dir"/*.sql "$deploy_dir"/**/*.sql; do
        if [[ ! -f $file || ! -f "$file.md5sum" ]]; then
            continue
        fi

        filekey=${file#*TO_DEPLOY}
        hash=$(<"${file}.md5sum")

        cat << EOF >> "$update_file"
            insert into tech.deploy_state
            values (
                select
                    '$filekey' as filekey
                    , '$hash' as hash
                    , current_timestamp() as run_time
                    , 'success' as status
            ) src
            ;
EOF
    done

    snowsql -c "${db}_${env}" \
        -o exit_on_error=true \
        -o friendly=false \
        -o quiet=true \
        -f "$update_file"
}

# Prepare scripts for deployment (replace placeholders, ...).
#   Remove  previously existing deploy folder
#   Copy all files from a selected version into deploy folder
#   Replace the ${db} placeholder with the proper env value
prepare_version() {
    local version_folder

    if [[ -z ${tgt_version} ]]; then
        tgt_version=$(__select_subdir "$PROG_DIR/../scripts")
    fi

    logging::info "Preparing [$tgt_version] in [$env]"

    version_folder="scripts/$tgt_version"

    if [[ -z $(find "./$version_folder" -type f) ]]; then
        logging::die "Version folder is empty"
    fi

    # remove previous data
    rm -rf "$deploy_dir"

    # create a copy of scripts folder
    mkdir -p "$deploy_dir"
    cp -r "$version_folder" "$deploy_dir"/

    # replace place holders in the source files
    for file in "$deploy_dir"/* "$deploy_dir"/**/*; do
        if [[ -f $file ]]; then
            md5sum "$file" | cut -d " " -f 1 > "${file}.md5sum"
            __replace_placeholder "$file" "$env"
        fi
    done

    __build_global_file

    logging::success "Preparation completed"
}

# Select the files to be deployed, based on the maintained state
prepare_diff() {
    local files_changed past_hash curr_hash query filekey prepd_file
    declare -A files_changed

    files_changed=()

    # remove previous data
    rm -rf "$deploy_dir"

    __retrieve_stored_state
    
    logging::info "Checking files for change"

    for file in scripts/*.sql scripts/**/*.sql; do
        if [[ ! -f $file ]]; then
            continue
        fi 

        filekey=${file#*scripts}

        past_hash=$(__get_stored_state "$filekey")

        curr_hash=$(md5sum "$file" | cut -d " " -f 1)
        
        if [[ "$curr_hash" == "$past_hash" ]]; then
            continue
        fi

        logging::info "Changes detected in [$filekey]"

        prepd_dir=$(echo "$deploy_dir$filekey" | rev | cut -d "/" -f 2- | rev)
        prepd_file="$deploy_dir$filekey"

        mkdir -p "$prepd_dir"
        cp "$file" "$prepd_file"
        
        __replace_placeholder "$prepd_file" "$env"
        echo "$curr_hash" > "${prepd_file}.md5sum"

        files_changed[$filekey]="$past_hash#$curr_hash"
    done

    if [[ ${#files_changed[@]} -eq 0 ]]; then
        logging::success "No change detected"
    else
        __build_global_file
        logging::success "Preparation completed"
    fi
}

# Run the prepared scripts with snowsql
#   Build a global sql file to be used by snowsql, calling all other sql files
#   Execute the produced script with snowsql
execute() {
    if [[ ! -d $deploy_dir ]]; then
        logging::die "No prepared version found"
    fi

    if ! __execute_global_file; then
        logging::die "Deployment failed"
    fi

    __maintain_state

    logging::success "Deployment successful"
}

# Clean the deployment artifacts
clean() {
    rm -rf "$deploy_dir"
    rm -f "$PROG_DIR"/deploy_*.log
}

# Main method of the script
#   Read and check the parameters
#   Perform the passed action
main() {
    local env tgt_version ask_for_confirmation deploy_dir global_version_file db state_file script_args action

    env=
    tgt_version=
    ask_for_confirmation=true
    deploy_dir="$PROG_DIR/TO_DEPLOY"
    global_version_file="$deploy_dir/global_version.sql"
    db=$(__get_repo_name)
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp/}$(basename "$0").XXXXXXXXXXXX")
    state_file="$tmp_dir/state.json"

    if ! __check_deps; then
        logging::die "Missing required dependency"
    fi

    # Get the options
    script_args=()
    while [[ $OPTIND -le $# ]]; do
        if getopts he:v:y option; then
            case $option in
                e) env="$OPTARG" ;;
                v) tgt_version="$OPTARG" ;;
                y) ask_for_confirmation=false ;;
                h) usage ;;
                \?) exit 1 ;;
            esac
        else
            script_args+=("${!OPTIND}")
            ((OPTIND++))
        fi
    done

    # Check that an action has been provided
    if [[ ${#script_args[@]} -ne 1 ]]; then
        logging::die "Missing action to perform. 'deploy.sh -h' for more information"
    fi

    action=${script_args:0}

    # Add default values if needed
    if [[ -z ${env} ]]; then
        env=$(__get_curr_branch_name)
    fi

    # Run action
    case "$action" in
        init) init "$state_file" ;;
        diff | prepare_diff) prepare_diff ;;
        prep | prepare) prepare_version ;;
        exec | execute) execute ;;
        clean) clean ;;
        *) logging::die "Invalid action '$action'. 'deploy.sh -h' for more information" ;;
    esac
}

trap __cleanup EXIT

main "$@"
