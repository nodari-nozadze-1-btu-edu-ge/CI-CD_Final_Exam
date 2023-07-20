# Set shell options for better script behavior
set -o errexit     # Exit immediately if a command fails
set -o nounset     # Exit if a variable is used without being set
set -o pipefail    # Exit if any command in a pipeline fails

# Enable tracing if BASH_TRACE environment variable is set to "1"
if [[ "${BASH_TRACE:-0}" == "1" ]]; then
    set -o xtrace
fi

# Check if the required GitHub personal access token is provided as an environment variable
if [ -z "$GITHUB_PERSONAL_ACCESS_TOKEN" ]; then
    echo "GITHUB_PERSONAL_ACCESS_TOKEN environment variable is missing"
    exit 1
fi

# Move to the directory containing the script
cd "$(dirname "$0")"

# Check if the script was provided with the correct number of arguments
if [ "$#" -eq 5 ]; then
    echo > /dev/null
else
    echo "The script was not provided with five arguments."
    echo "Usage: ./mid-term.sh CODE_REPO_URL CODE_DEV_BRANCH_NAME CODE_RELEASE_BRANCH_NAME REPORT_REPO_URL REPORT_BRANCH_NAME"
    exit 1
fi

# Store the provided arguments into meaningful variables
CODE_REPO_URL="$1"
CODE_DEV_BRANCH_NAME="$2"
CODE_RELEASE_BRANCH_NAME="$3"
REPORT_REPO_URL="$4"
REPORT_BRANCH_NAME="$5"

# Extract repository and owner names from the provided URLs
REPOSITORY_NAME_CODE=$(basename "$CODE_REPO_URL" .git)
REPOSITORY_OWNER=$(echo "$CODE_REPO_URL" | awk -F':' '{print $2}' | awk -F'/' '{print $1}')
REPORT_REPOSITORY_OWNER=$(echo "$REPORT_REPO_URL" | awk -F':' '{print $2}' | awk -F'/' '{print $1}')
REPOSITORY_NAME_REPORT=$(basename "$REPORT_REPO_URL" .git)

# Create temporary directories to clone repositories and store reports
REPOSITORY_PATH_CODE=$(mktemp --directory)
REPOSITORY_PATH_REPORT=$(mktemp --directory)
PYTEST_REPORT_PATH=""
BLACK_REPORT_PATH=""
BLACK_OUTPUT_PATH=""
PYTEST_RESULT=0
BLACK_RESULT=0

# Function to clean up temporary files and directories upon script termination
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

# Register cleanup function to be executed upon script termination or interruption
trap cleanup INT EXIT ERR SIGINT SIGTERM

# Function to make GitHub API GET requests
function github_api_get_request() {
    curl --request GET \
        --header "Accept: application/vnd.github+json" \
        --header "Authorization: Bearer $GITHUB_PERSONAL_ACCESS_TOKEN" \
        --header "X-GitHub-Api-Version: 2022-11-28" \
        --output "$2" \
        --silent \
        "$1"
}

# Function to make GitHub API POST requests
function github_post_request() {
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
function jq_update() {
    local IO_PATH=$1
    local TEMP_PATH=$(mktemp)
    shift
    cat $IO_PATH | jq "$@" > $TEMP_PATH
    mv $TEMP_PATH $IO_PATH
}

# Clone the code repository into the temporary directory
git clone $CODE_REPO_URL $REPOSITORY_PATH_CODE

# Move to the code repository directory
cd $REPOSITORY_PATH_CODE

# Switch to the specified development branch
git switch $CODE_DEV_BRANCH_NAME

# Store the hash of the last commit on the development branch
LAST_COMMIT="$(git log -n 1 --format=%H)"

# Continuously check for new commits on the development branch
while true; do
    # Switch to the development branch and fetch updates
    git switch $CODE_DEV_BRANCH_NAME > /dev/null 2>&1
    git fetch $1 $2 > /dev/null 2>&1

    # Check if there are new commits since the last check
    CHECK_COMMIT=$(git rev-parse FETCH_HEAD)
    if [ "$CHECK_COMMIT" != "$LAST_COMMIT" ]; then
        # Retrieve the list of commits between the last commit and the latest one
        COMMITS=$(git log --pretty=format:"%H" --reverse $LAST_COMMIT..$CHECK_COMMIT)
        echo "$COMMITS"

        # Process each commit individually
        LAST_COMMIT=$CHECK_COMMIT
        for COMMIT in $COMMITS; do
            echo $COMMIT

            # Create temporary files to store test reports and black output
            PYTEST_REPORT_PATH=$(mktemp)
            BLACK_OUTPUT_PATH=$(mktemp)
            BLACK_REPORT_PATH=$(mktemp)

            # Checkout the specific commit
            git checkout $COMMIT

            # Extract the author's email from the commit
            AUTHOR_EMAIL=$(git log -n 1 --format="%ae" HEAD)

            # Run pytest and store the result in PYTEST_RESULT
            if pytest --verbose --html=$PYTEST_REPORT_PATH --self-contained-html; then
                PYTEST_RESULT=$?
                echo "PYTEST SUCCEEDED $PYTEST_RESULT"
            else
                PYTEST_RESULT=$?
                echo "PYTEST FAILED $PYTEST_RESULT"

                # Perform git bisect to find the first bad commit for pytest failures
                git bisect start
                git bisect good ${CODE_DEV_BRANCH_NAME}-ci-success
                git bisect bad HEAD
                git bisect run pytest
                PYTEST_FIRST_BAD_COMMIT=$(git bisect view --pretty=%H)
                git bisect reset
            fi

            # Run black formatter and store the result in BLACK_RESULT
            if black --check --diff *.py > $BLACK_OUTPUT_PATH; then
                BLACK_RESULT=$?
                echo "BLACK SUCCEEDED $BLACK_RESULT"
            else
                BLACK_RESULT=$?
                echo "BLACK FAILED $BLACK_RESULT"

                # Generate a black report in HTML format and perform git bisect to find the first bad commit for black failures
                cat $BLACK_OUTPUT_PATH | pygmentize -l diff -f html -O full,style=solarized-light -o $BLACK_REPORT_PATH
                git bisect start
                git bisect good ${CODE_DEV_BRANCH_NAME}-ci-success
                git bisect bad HEAD
                git bisect run black --check --diff *.py
                BLACK_FIRST_BAD_COMMIT=$(git bisect view --pretty=%H)
                git bisect reset
            fi

            # Check the test and formatting results to determine if a report should be created
            if (( ($PYTEST_RESULT != 0)|| ( $BLACK_RESULT != 0) )); then
                # Clone the report repository if it doesn't exist or is empty
                if [ "$(ls -A "$REPOSITORY_PATH_REPORT")" ]; then
                    echo "Directory $REPOSITORY_PATH_REPORT exists and is not empty. Skipping cloning."
                else
                    git clone "$REPORT_REPO_URL" "$REPOSITORY_PATH_REPORT"
                fi

                # Move to the report repository directory
                pushd $REPOSITORY_PATH_REPORT

                # Switch to the specified report branch
                git switch $REPORT_BRANCH_NAME

                # Create a directory for the current commit's report
                REPORT_PATH="${COMMIT}-$(date +%s)"
                mkdir --parents $REPORT_PATH

                # Copy pytest report to the report directory
                cp $PYTEST_REPORT_PATH "$REPORT_PATH/pytest.html"

                # Copy black report to the report directory if it exists
                if [ -s "$BLACK_REPORT_PATH" ]; then
                    cp $BLACK_REPORT_PATH "$REPORT_PATH/black.html"
                fi

                # Add the report directory to the report repository
                git add $REPORT_PATH
                git commit -m "$COMMIT report."
                git push

                # Return to the code repository directory
                popd
            fi

            # Create a GitHub issue if there are test or formatting failures
            if (( ($PYTEST_RESULT != 0)|| ( $BLACK_RESULT != 0) )); then
                AUTHOR_USERNAME=""
                RESPONSE_PATH=$(mktemp)

                # Use GitHub API to search for the author's username based on their email
                github_api_get_request "https://api.github.com/search/users?q=$AUTHOR_EMAIL" $RESPONSE_PATH

                TOTAL_USER_COUNT=$(cat $RESPONSE_PATH | jq ".total_count")

                if [[ $TOTAL_USER_COUNT == 1 ]]; then
                    USER_JSON=$(cat $RESPONSE_PATH | jq ".items[0]")
                    AUTHOR_USERNAME=$(cat $RESPONSE_PATH | jq --raw-output ".items[0].login")
                fi

                REQUEST_PATH=$(mktemp)
                RESPONSE_PATH=$(mktemp)
                echo "{}" > $REQUEST_PATH

                # Construct the body of the GitHub issue
                BODY+="Automatically generated message

"
                if (( $PYTEST_RESULT != 0 )); then
                    if (( $BLACK_RESULT != 0 )); then
                        if [[ "$PYTEST_RESULT" -eq "5" ]]; then
                            TITLE="${COMMIT::7} Unit tests do not exist in the repository or do not work correctly and formatting test failed."
                            BODY+="${COMMIT} Unit tests do not exist in the repository or do not work correctly and formatting test failed.
"
                            BODY+="first bad commit for pytest was $PYTEST_FIRST_BAD_COMMIT and for black $BLACK_FIRST_BAD_COMMIT
"
                            jq_update $REQUEST_PATH '.labels = ["ci-pytest", "ci-black"]'
                        else
                            TITLE="${COMMIT::7} failed unit and formatting tests."
                            BODY+="${COMMIT} failed unit and formatting tests.
"
                            BODY+="first bad commit for pytest was $PYTEST_FIRST_BAD_COMMIT and for black $BLACK_FIRST_BAD_COMMIT
"
                            jq_update $REQUEST_PATH '.labels = ["ci-pytest", "ci-black"]'
                        fi
                    else
                        if [[ "$PYTEST_RESULT" -eq "5" ]]; then
                            TITLE="${COMMIT::7} Unit tests do not exist in the repository or do not work correctly and formatting test passed."
                            BODY+="${COMMIT} Unit tests do not exist in the repository or do not work correctly and formatting test passed.
"
                            BODY+="first bad commit for pytest was $PYTEST_FIRST_BAD_COMMIT
"
                        else
                            TITLE="${COMMIT::7} failed unit tests."
                            BODY+="${COMMIT} failed unit tests.
"
                            BODY+="first bad commit for pytest was $PYTEST_FIRST_BAD_COMMIT
"
                            jq_update $REQUEST_PATH '.labels = ["ci-pytest"]'
                        fi
                    fi
                else
                    TITLE="${COMMIT::7} failed formatting test."
                    BODY+="${COMMIT} failed formatting test.
"
                    BODY+="first bad commit for black was $BLACK_FIRST_BAD_COMMIT
"
                    jq_update $REQUEST_PATH '.labels = ["ci-black"]'
                fi

                BODY+="Pytest report: https://${REPORT_REPOSITORY_OWNER}.github.io/${REPOSITORY_NAME_REPORT}/$REPORT_PATH/pytest.html
"
                if [ -s "$BLACK_REPORT_PATH" ]; then
                    BODY+="Black report: https://${REPORT_REPOSITORY_OWNER}.github.io/${REPOSITORY_NAME_REPORT}/$REPORT_PATH/black.html
"
                fi

                jq_update $REQUEST_PATH --arg title "$TITLE" '.title = $title'
                jq_update $REQUEST_PATH --arg body  "$BODY"  '.body = $body'

                if [[ ! -z $AUTHOR_USERNAME ]]; then
                    jq_update $REQUEST_PATH --arg username "$AUTHOR_USERNAME"  '.assignees = [$username]'
                fi

                # Use GitHub API to create the issue
                github_post_request "https://api.github.com/repos/${REPOSITORY_OWNER}/${REPOSITORY_NAME_CODE}/issues" $REQUEST_PATH $RESPONSE_PATH
                cat $RESPONSE_PATH | jq ".html_url"
                rm $RESPONSE_PATH
                rm $REQUEST_PATH
                BODY=""

                # Remove temporary files and directories related to the reports
                rm -rf $PYTEST_REPORT_PATH
                rm -rf $BLACK_OUTPUT_PATH
                rm -rf $BLACK_REPORT_PATH
                rm -rf $REPORT_PATH
            else
                # Mark the commit as successful and push the tags to the code repository
                REMOTE_NAME=$(git remote)
                git tag --force "${CODE_DEV_BRANCH_NAME}-ci-success" $COMMIT
                git push --force $REMOTE_NAME $CODE_DEV_BRANCH_NAME --tags

                # Attempt to merge the commit to the release branch
                MERGE_RESULT=$(mktemp)
                git checkout $CODE_RELEASE_BRANCH_NAME
                git pull $REMOTE_NAME $CODE_RELEASE_BRANCH_NAME
                if git merge $COMMIT > $MERGE_RESULT; then
                    git push
                else
                    # If a merge conflict occurs, create a GitHub issue to notify the developer
                    REQUEST_PATH=$(mktemp)
                    RESPONSE_PATH=$(mktemp)
                    echo "{}" > $REQUEST_PATH
                    BODY+="Automatically generated message
"
                    TITLE="${COMMIT::7} merge conflict"
                    BODY+="$(cat $MERGE_RESULT)
"
                    jq_update $REQUEST_PATH --arg title "$TITLE" '.title = $title'
                    jq_update $REQUEST_PATH --arg body  "$BODY"  '.body = $body'
                    github_post_request "https://api.github.com/repos/${REPOSITORY_OWNER}/${REPOSITORY_NAME_CODE}/issues" $REQUEST_PATH $RESPONSE_PATH
                    cat $RESPONSE_PATH | jq ".html_url"
                    BODY=""
                    git reset --merge
                    rm -rf $REQUEST_PATH
                    rm -rf $RESPONSE_PATH
                    rm -rf $MERGE_RESULT
                fi
            fi
        done
    fi

    # Wait for 15 seconds before checking for new commits again
    sleep 15
done
