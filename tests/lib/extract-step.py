"""Print the `run:` script of one step of a workflow, so tests execute the exact shipped code.

Usage: python3 extract-step.py <workflow.yml> <job-id> <step-id>
"""
import sys

import yaml

path, job_id, step_id = sys.argv[1:4]
with open(path) as f:
    workflow = yaml.safe_load(f)
for step in workflow["jobs"][job_id]["steps"]:
    if step.get("id") == step_id:
        sys.stdout.write(step["run"])
        sys.exit(0)
sys.exit(f"step '{step_id}' not found in job '{job_id}' of {path}")
