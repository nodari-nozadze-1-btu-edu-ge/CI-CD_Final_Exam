#!/bin/bash

# Exit on any error, unset variable, or failed pipe
set -o errexit
set -o nounset
set -o pipefail

# Enable debugging if BASH_TRACE is set to 1
if [[ "${BASH_TRACE:-0}" == "1" ]]; then
    set -o xtrace
fi

# Check for the presence of the GitHub personal access token
if [ -z "$GITHUB_PERSONAL_ACCESS_TOKEN" ]; then
    echo "GITHUB_PERSONAL_ACCESS_TOKEN environment variable is missing"
    exit 1
fi

# Set up variables
cd "$(dirname "$0")"
if [ "$#" -eq 5 ]; then
    echo > /dev/null
else
    echo "The script was not provided with four arguments."
    echo "Usage: ./mid-term.sh CODE_REPO_URL CODE_DEV_BRANCH_NAME CODE_RELEASE_BRANCH_NAME REPORT_REPO_URL REPORT_BRANCH_NAME"
    exit 1
fi
CODE_REPO_URL="$1"
CODE_DEV_BRANCH_NAME="$2"
CODE_RELEASE_BRANCH_NAME="$3"
REPORT_REPO_URL="$4"
REPORT_BRANCH_NAME="$5"
REPOSITORY_NAME_CODE=$(basename "$CODE_REPO_URL" .git)
REPOSITORY_OWNER=$(echo "$CODE_REPO_URL" | awk -F':' '{print $2}' | awk -F'/' '{print $1}')
REPORT_REPOSITORY_OWNER=$(echo "$REPORT_REPO_URL" | awk -F':' '{print $2}' | awk -F'/' '{print $1}')
REPOSITORY_NAME_REPORT=$(basename "$REPORT_REPO_URL" .git)
REPOSITORY_PATH_CODE=$(mktemp --directory)
REPOSITORY_PATH_REPORT=$(mktemp --directory)
PYTEST_REPORT_PATH=""
BLACK_REPORT_PATH=""
BLACK_OUTPUT_PATH=""
PYTEST_RESULT=0
BLACK_RESULT=0

# Check if the provided CODE_REPO_URL exists and the specified branches exist
if git ls-remote --exit-code "$CODE_REPO_URL" &> /dev/null; then
    if git ls-remote --exit-code --heads "$CODE_REPO_URL" "$CODE_DEV_BRANCH_NAME" &> /dev/null; then
        echo > /dev/null
    else
        echo "Branch '$CODE_DEV_BRANCH_NAME' does not exist"
        exit 1
    fi
else
    echo "Repository does not exist"
    exit 1
fi

# Check if the provided REPORT_REPO_URL exists and the specified branch exists
if git ls-remote --exit-code "$REPORT_REPO_URL" &> /dev/null; then
    echo > /dev/null
    if git ls-remote --exit-code --heads "$REPORT_REPO_URL" "$REPORT_BRANCH_NAME" &> /dev/null; then
        echo > /dev/null
    else
        echo "Branch '$REPORT_BRANCH_NAME' does not exist"
        exit 1
    fi
else
    echo "Repository does not exist"
    exit 1
fi

# Check if pytest and black are installed
if ! pytest --version >/dev/null 2>&1; then
    echo "pytest is not installed"
    exit 1
fi

if ! black --version >/dev/null 2>&1; then
    echo "black is not installed"
    exit 1
fi

# Function to clean up temporary files and directories
cleanup() {
    echo "Cleaning up..."
    if [ -d "$REPOSITORY_PATH_CODE" ]; then
        rm -rf "$REPOSITORY_PATH_CODE"
        echo "Deleted REPOSITORY_PATH_CODE"
    fi
    if [ -d "$REPOSITORY_PATH_REPORT" ]; then
        rm -rf "$REPOSITORY_PATH_REPORT"
        echo "Deleted REPOSITORY_PATH_REPORT"
    fi
    if [ -f "$PYTEST_REPORT_PATH" ]; then
        rm -rf "$PYTEST_REPORT_PATH"
        echo "Deleted PYTEST_REPORT_PATH"
    fi
    if [ -f "$BLACK_REPORT_PATH" ]; then
        rm -rf "$BLACK_REPORT_PATH"
        echo "Deleted BLACK_REPORT_PATH"
    fi
    if [ -f "$BLACK_OUTPUT_PATH" ]; then
        rm -rf "$BLACK_OUTPUT_PATH"
        echo "Deleted BLACK_OUTPUT_PATH"
    fi   
}

# Trap to call the cleanup function on script termination
trap cleanup INT EXIT ERR SIGINT SIGTERM

# Function to make a GitHub API GET request
function github_api_get_request()
{
    curl --request GET \
        --header "Accept: application/vnd.github+json" \
        --header "Authorization: Bearer $GITHUB_PERSONAL_ACCESS_TOKEN" \
        --header "X-GitHub-Api-Version: 2022-11-28" \
        --output "$2" \
        --silent \
        "$1"
}

# Function to make a GitHub API POST request
function github_post_request()
{
    curl --request POST \
        --header "Accept: application/vnd.github+json" \
        --header "Authorization: Bearer $GITHUB_PERSONAL_ACCESS_TOKEN" \
        --header "X-GitHub-Api-Version: 2022-11-28" \
        --header "Content-Type: application/json" \
        --silent \
        --output "$3" \
        --data-binary "@$2" \
        "$1"
}

# Function to update a JSON file using jq
function jq_update()
{
    local IO_PATH=$1
    local TEMP_PATH=$(mktemp)
    shift
    cat $IO_PATH | jq "$@" > $TEMP_PATH
    mv $TEMP_PATH $IO_PATH
}

# Clone the CODE_REPO_URL into the temporary directory
git clone $CODE_REPO_URL $REPOSITORY_PATH_CODE
cd $REPOSITORY_PATH_CODE

# Get the last commit from the CODE_DEV_BRANCH_NAME
git switch $CODE_DEV_BRANCH_NAME
LAST_COMMIT="$(git log -n 1 --format=%H)"

# Main loop to continuously monitor and process commits
while true; do
    git switch $CODE_DEV_BRANCH_NAME > /dev/null 2>&1
    git fetch $1 $2 > /dev/null 2>&1
    CHECK_COMMIT=$(git rev-parse FETCH_HEAD)

    # Check if there are new commits to process
    if [ "$CHECK_COMMIT" != "$LAST_COMMIT" ]; then
        COMMITS=$(git log --pretty=format:"%H" --reverse $LAST_COMMIT..$CHECK_COMMIT)
        echo "$COMMITS"
        LAST_COMMIT=$CHECK_COMMIT

        # Loop through each commit and perform tests
        for COMMIT in $COMMITS; do
            echo $COMMIT
            PYTEST_REPORT_PATH=$(mktemp)
            BLACK_OUTPUT_PATH=$(mktemp)
            BLACK_REPORT_PATH=$(mktemp)
            git checkout $COMMIT
            AUTHOR_EMAIL=$(git log -n 1 --format="%ae" HEAD)

            # Run pytest and check the result
            if pytest --verbose --html=$PYTEST_REPORT_PATH --self-contained-html; then
                PYTEST_RESULT=$?
                echo "PYTEST SUCCEEDED $PYTEST_RESULT"
            else
                PYTEST_RESULT=$?
                echo "PYTEST FAILED $PYTEST_RESULT"
                git bisect start
                git bisect good ${CODE_DEV_BRANCH_NAME}-ci-success
                git bisect bad HEAD
                git bisect run pytest
                PYTEST_FIRST_BAD_COMMIT=$(git bisect view --pretty=%H)
                git bisect reset
            fi

            # Run black and check the result
            if black --check --diff *.py > $BLACK_OUTPUT_PATH; then
                BLACK_RESULT=$?
                echo "BLACK SUCCEEDED $BLACK_RESULT"
            else
                BLACK_RESULT=$?
                echo "BLACK FAILED $BLACK_RESULT"
                cat $BLACK_OUTPUT_PATH | pygmentize -l diff -f html -O full,style=solarized-light -o $BLACK_REPORT_PATH
                git bisect start
                git bisect good ${CODE_DEV_BRANCH_NAME}-ci-success
                git bisect bad HEAD
                git bisect run black --check --diff *.py
                BLACK_FIRST_BAD_COMMIT=$(git bisect view --pretty=%H)
                git bisect reset
            fi

            # Create GitHub issue if either pytest or black test fails
            if (( ($PYTEST_RESULT != 0) || ( $BLACK_RESULT != 0) )); then
                if [ "$(ls -A "$REPOSITORY_PATH_REPORT")" ]; then
                    echo "Directory $REPOSITORY_PATH_REPORT exists and is not empty. Skipping cloning."
                else
                    git clone "$REPORT_REPO_URL" "$REPOSITORY_PATH_REPORT"
                fi
                pushd $REPOSITORY_PATH_REPORT
                git switch $REPORT_BRANCH_NAME
                REPORT_PATH="${COMMIT}-$(date +%s)"
                mkdir --parents $REPORT_PATH
                cp $PYTEST_REPORT_PATH "$REPORT_PATH/pytest.html"
                if [ -s "$BLACK_REPORT_PATH" ]; then
                    cp $BLACK_REPORT_PATH "$REPORT_PATH/black.html"
                fi
                git add $REPORT_PATH
                git commit -m "$COMMIT report."
                git push
                popd
            fi

            # Create GitHub issue if either pytest or black test fails
            if (( ($PYTEST_RESULT != 0) || ( $BLACK_RESULT != 0) )); then
                AUTHOR_USERNAME=""
                RESPONSE_PATH=$(mktemp)
                github_api_get_request "https://api.github.com/search/users?q=$AUTHOR_EMAIL" $RESPONSE_PATH

                TOTAL_USER_COUNT=$(cat $RESPONSE_PATH | jq ".total_count")

                if [[ $TOTAL_USER_COUNT == 1 ]]; then
                    USER_JSON=$(cat $RESPONSE_PATH | jq ".items[0]")
                    AUTHOR_USERNAME=$(cat $RESPONSE_PATH | jq --raw-output ".items[0].login")
                fi

                REQUEST_PATH=$(mktemp)
                RESPONSE_PATH=$(mktemp)
                echo "{}" > $REQUEST_PATH

                BODY+="Automatically generated message\n"
                if (( $PYTEST_RESULT != 0 )); then
                    if (( $BLACK_RESULT != 0 )); then
                        if [[ "$PYTEST_RESULT" -eq "5" ]]; then
                            TITLE="${COMMIT::7} Unit tests do not exist in the repository or do not work correctly and formatting test failed ."
                            BODY+="${COMMIT} Unit tests do not exist in the repository or do not work correctly and formatting test failed .\n"
                            BODY+="first bad commit for pytest was $PYTEST_FIRST_BAD_COMMIT and for black $BLACK_FIRST_BAD_COMMIT\n"
                            jq_update $REQUEST_PATH '.labels = ["ci-pytest", "ci-black"]'
                        else
                            TITLE="${COMMIT::7} failed unit and formatting tests ."
                            BODY+="${COMMIT} failed unit and formatting tests .\n"                            
                            BODY+="first bad commit for pytest was $PYTEST_FIRST_BAD_COMMIT and for black $BLACK_FIRST_BAD_COMMIT\n"
                            jq_update $REQUEST_PATH '.labels = ["ci-pytest", "ci-black"]'
                        fi
                    else
                        if [[ "$PYTEST_RESULT" -eq "5" ]]; then
                            TITLE="${COMMIT::7} Unit tests do not exist in the repository or do not work correctly and formatting test passed ."
                            BODY+="${COMMIT} Unit tests do not exist in the repository or do not work correctly and formatting test passed .\n"
                            BODY+="first bad commit for pytest was $PYTEST_FIRST_BAD_COMMIT\n"
                        else
                            TITLE="${COMMIT::7} failed unit tests ."
                            BODY+="${COMMIT} failed unit tests .\n"