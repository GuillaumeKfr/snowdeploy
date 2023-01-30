# snowdeploy

## Usage

Prepare and deploy version scripts for Snowflake.

Syntax: `deploy.sh action [-e env] [-v] [-y] [-h]`

### Parameters:

action  Action to perform. Possible values:
 - `init`: Setup the deployment structures in Snowflake
 - `prep[are]`: Prepare the scripts files for a given version
 - `[prepare_]diff`: Prepare the scripts files based on last saved state
 - `exec[ute]`: Run the prepared scripts
 - `clean`: Remove deploy folder and logs

### Options:

 - `e`  Target deployment env (dev/uat/prod). Defaults to current git branch.
 - `v`  Version to be deployed. Can be selected at runtime.
 - `y`  Do not ask for confirmation before deploying.
 - `h`  Display this help.

## External dependencies:
 - SnowSQL
 - JQ

## Integration in existing repo

### Add submodule

```sh
git submodule add <remote_url> <destination_folder>
```

### Pull submodule

```sh
git submodule update --init --recursive
``` 

### Refresh submodule

```sh
git submodule update --remote --merge
``` 
