Automated Testing and Reporting Script
This script is a Bash-based tool designed to automate testing and reporting for a given Git repository containing Python code. The script uses pytest and black for testing and formatting checks, respectively. If tests fail, it creates a GitHub issue with detailed information about the failed tests and formatting issues.

Prerequisites
Before running this script, ensure you have the following dependencies installed on your system:

Python (with pytest) - for running unit tests
black - for code formatting checks
cURL - to make API requests to GitHub
GitHub Personal Access Token - to authenticate API requests (required environment variable: GITHUB_PERSONAL_ACCESS_TOKEN)
Usage
vbnet
Copy code
bash mid-term.sh CODE_REPO_URL CODE_DEV_BRANCH_NAME CODE_RELEASE_BRANCH_NAME REPORT_REPO_URL REPORT_BRANCH_NAME
Replace the placeholders with the appropriate values:

CODE_REPO_URL: The URL of the Git repository containing the Python code to be tested and reported.
CODE_DEV_BRANCH_NAME: The name of the development branch in the CODE_REPO_URL repository.
CODE_RELEASE_BRANCH_NAME: The name of the release branch in the CODE_REPO_URL repository.
REPORT_REPO_URL: The URL of the Git repository where the test reports will be stored.
REPORT_BRANCH_NAME: The name of the branch in the REPORT_REPO_URL repository where test reports will be committed.
How it Works
The script checks if the provided CODE_REPO_URL exists and verifies the existence of the specified CODE_DEV_BRANCH_NAME and CODE_RELEASE_BRANCH_NAME.

Similarly, the script checks if the provided REPORT_REPO_URL exists and verifies the existence of the specified REPORT_BRANCH_NAME.

The script then checks if pytest and black are installed on the system.

The script clones the CODE_REPO_URL repository into a temporary directory.

It continuously monitors the CODE_DEV_BRANCH_NAME for new commits. Once a new commit is found, it performs the following steps:

a. Runs pytest for unit testing and black for code formatting on the repository code.
b. If either pytest or black tests fail, it creates a GitHub issue in the REPORT_REPO_URL repository with detailed information about the failed tests and formatting issues.

If tests pass successfully, the script creates a GitHub issue in the CODE_REPO_URL repository for any merge conflict with the CODE_RELEASE_BRANCH_NAME.

The script cleans up temporary files and directories after execution.

Automation and Reporting
The script uses GitHub API to fetch and create issues.
It creates an automated GitHub issue with detailed information for each test failure.
The test reports (pytest and black) are stored in the REPORT_REPO_URL repository.
Cleanup
The script automatically cleans up any temporary files and directories created during the execution.

Contributions and Issues
Please feel free to contribute to this script by creating pull requests or reporting any issues you encounter. We appreciate your feedback and contributions to make this tool more robust and efficient.

Happy Testing!