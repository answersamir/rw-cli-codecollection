#!/bin/bash
# filepath: /home/runwhen/codecollection/codebundles/azure-planned-maintenance-manager/create_issues.sh
set -euo pipefail

# -----------------------------------------------------------------------------
# Script: create_issues.sh
# Purpose: Creates issues from Azure maintenance events for tracking and remediation.
#
# Inputs (Environment Variables):
#   INPUT_FILE  (Optional): Path to the maintenance events JSON file (default: ./maintenance_events.json)
#   OUTPUT_FILE (Optional): Path to save the issues JSON file (default: ./issues.json)
#
# Outputs:
#   File: issues.json - Formatted issues from maintenance events
# -----------------------------------------------------------------------------

# Set default values - Fix syntax error (removed line breaks after values)
INPUT_FILE=${INPUT_FILE:-"./maintenance_events.json"}
OUTPUT_FILE=${OUTPUT_FILE:-"./issues.json"}

echo "--- Creating issues from maintenance events ---"
echo "Input file: $INPUT_FILE"
echo "Output file: $OUTPUT_FILE"

# Uncomment and fix the file check - this is important!
# Check if input file exists
if [ ! -f "$INPUT_FILE" ]; then
    echo "ERROR: Input file $INPUT_FILE not found!" >&2
    pwd
    ls -la
    exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "ERROR: jq is required but not installed!" >&2
    exit 1
fi

# Get the command that was used to generate the maintenance events
maintenance_cmd="az graph query -q \"ServiceHealthResources | where type =~ 'Microsoft.ResourceHealth/events' | where properties.EventType == 'PlannedMaintenance'\""

# Process maintenance events and create issues
jq --arg cmd "$maintenance_cmd" '
[
  .[] | {
    title: .description,
    severity: (
      if .level == "Informational" then 3
      elif .level == "Warning" then 2
      else 1
      end
    ),
    next_steps: (
      "1. Review maintenance details for resources\n" +
      "2. Check impact duration: " + ((.impactStartTime | tostring) // "Unknown") + " to " + ((.impactMitigationTime | tostring) // "Unknown") + "\n" +
      "3. Plan for potential downtime or degraded performance\n" +
      "4. Create mitigation plan if needed"
    ),
    details: {
      event_id: .id,
      tracking_id: .trackingId,
      summary: .summary,
      impact: .impact,
      impacted_resources: .impactedResources,
      start_time: .impactStartTime,
      end_time: .impactMitigationTime,
      status: .status
    }
  }
]' "$INPUT_FILE" > "$OUTPUT_FILE"

# Check if issues were created - Fix syntax error (removed line breaks in condition)
issue_count=$(jq 'length' "$OUTPUT_FILE")
echo "Created $issue_count issues from maintenance events."

if [ "$issue_count" -eq 0 ]; then
    echo "No issues were created. This could be because there were no maintenance events with impacted resources."
else
    echo "Issues saved to $OUTPUT_FILE"
fi

echo "--- Issue creation complete ---"
exit 0