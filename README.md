# Wait for Workflow Action

[![Test WaitForWorkflow](https://github.com/kamilchodola/wait-for-workflow-action/actions/workflows/test.yml/badge.svg)](https://github.com/kamilchodola/wait-for-workflow-action/actions/workflows/test.yml)

> **Security Notice:** This action has been security-hardened. See [SECURITY.md](SECURITY.md) for the full audit report and details of all fixes applied.

This GitHub Action waits for a specified workflow to complete before proceeding with the next steps in your workflow. It is useful when you have dependent workflows and want to ensure that one completes successfully before continuing with the next. For example, you might want to ensure that a build or test workflow finishes successfully before starting a deployment workflow.

## Inputs

| Input            | Description                                         | Required | Default |
|------------------|-----------------------------------------------------|----------|---------|
| `GITHUB_TOKEN`   | GitHub token to access the repository and its APIs  | Yes      |         |
| `workflow_id`    | ID of the workflow to wait for                      | No       |         |
| `run_id`         | If provided will wait for workflow run with specified id                     | No       |         |
| `max_wait_minutes`| Maximum time script will wait to workflow run to be found in minutes      | No       | 5       |
| `interval`| Interval in seconds which will be used for GitHub API calls      | No       | 10       |
| `timeout`| Maximum time script will wait to workflow run to be finished      | No       | 30       |
| `org_name`   | Organization name where the repository is located   | Yes      |         |
| `repo_name`     | Repository name to monitor for the workflow run     | Yes      |         |
| `ref`            | Branch reference to watch for the workflow run      | No       |         |

## How It Works

This action performs the following steps:

1. Retrieves the current time in ISO 8601 format.
2. Loops until the specified workflow is triggered:
   - Sends a request to the GitHub API to get the list of workflow runs for the specified workflow ID.
   - Filters the list of workflow runs based on the provided `ref` (branch) and the run creation time.
   - Checks if the maximum waiting time has been reached. If so, exits with an error message.
   - Sleeps for 30 seconds before checking again if the workflow has been triggered.
3. Once the workflow is triggered, loops until the workflow run is completed:
   - Sends a request to the GitHub API to get the status of the specified workflow run.
   - Checks if the status is "completed". If so, proceeds to the next step.
   - Sleeps for 30 seconds before checking again if the workflow has been completed.
4. When the workflow run is completed, checks its conclusion:
   - If the conclusion is "success", the action exits successfully.
   - If the conclusion is anything other than "success", the action exits with an error message.


## Usage

To use this action, add it to your workflow file with the appropriate inputs:

```yaml
- name: Wait for Workflow Action
  uses: kamilchodola/wait-for-workflow-action@1.1.0
  with:
    GITHUB_TOKEN: ${{ secrets.REPOSITORY_DISPATCH_TOKEN }}
    workflow_id: 'workflow_name.yml'
    max_wait_minutes: '3'
    interval: '5'
    timeout: '60'
    org_name: 'your-organization'
    repo_name: 'your-repository'
    ref: '${{ github.ref }}'
```

In case, you already have run_id, you can pass it this way:

```yaml
- name: Wait for Workflow Action
  uses: kamilchodola/wait-for-workflow-action@1.1.0
  with:
    GITHUB_TOKEN: ${{ secrets.REPOSITORY_DISPATCH_TOKEN }}
    workflow_id: 'workflow_name.yml'
    run_id: '123123'
    org_name: 'your-organization'
    repo_name: 'your-repository'
    ref: '${{ github.ref }}'
```

## Notes

- If the `ref` input is not provided or is left empty, the action will use the current `github.ref` as the branch reference. This is useful when you want to wait for a workflow run on the same branch that triggered the current workflow.

## Security Recommendations

- Always pass `GITHUB_TOKEN` via `secrets.*` — never hard-code it in your workflow file.
- Grant the token only the minimum required scopes (`actions: read` is sufficient for most use-cases).
- See [SECURITY.md](SECURITY.md) for the full security audit and a description of all hardening measures applied to this action.
- The `max_wait_minutes` input controls how long the action waits **for the workflow run to appear** (i.e. to be triggered). The default is 5 minutes. If the run has not been detected within this window, the action exits with an error. Increase `max_wait_minutes` if your workflow takes longer to be queued after dispatch.
- The `timeout` input controls how long the action waits **for the detected run to complete**. The default is 30 minutes. If the workflow does not finish within this window, the action exits with an error. Increase `timeout` if your workflow takes longer to execute.
- Keep in mind that the GitHub Actions runner has a default timeout of 6 hours for a job, so ensure the sum of `max_wait_minutes` and `timeout` falls within this limit.
