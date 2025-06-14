#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Script: get_maintenance_events.sh
# Purpose: Fetches active and upcoming planned maintenance events from Azure
#          Service Health and their impacted resources for the specified subscription 
#          and optionally a resource group.
#
# Inputs (Environment Variables):
#   AZURE_RESOURCE_SUBSCRIPTION_ID   (Required): Azure Subscription ID.
#   AZURE_RESOURCE_GROUP    (Optional): Name of the Azure Resource Group to scope the search.
#   OUTPUT_DIR              (Required): Directory to save the output JSON file.
#
# Outputs:
#   File: ${OUTPUT_DIR}/maintenance_events.json
#         Contains an array of Azure Resource Health event objects with their impacted resources.
# -----------------------------------------------------------------------------

az login --service-principal --username "$AZ_USERNAME" --password "$AZ_SECRET_VALUE" --tenant "$AZ_TENANT"


# Get or set subscription ID
if [ -z "$AZURE_RESOURCE_SUBSCRIPTION_ID" ]; then
    subscription=$(az account show --query "id" -o tsv)
    echo "AZURE_RESOURCE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription"
else
    subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
    echo "Using specified subscription ID: $subscription"
fi

# Set the subscription ID
echo "Switching to subscription ID: $subscription"
az account set --subscription "$subscription" || { echo "Failed to set subscription."; exit 1; }

OUTPUT_DIR="."
output_file="${OUTPUT_DIR}/maintenance_events.json"
events_temp_file="${OUTPUT_DIR}/events_temp.json"
resources_temp_file="${OUTPUT_DIR}/resources_temp.json"

# Ensure output directory exists
mkdir -p "$OUTPUT_DIR"

echo "--- Starting Azure Planned Maintenance Event Retrieval ---"
echo "Subscription ID: $AZURE_RESOURCE_SUBSCRIPTION_ID"
if [[ -n "${AZURE_RESOURCE_GROUP:-}" ]]; then
    echo "Resource Group: $AZURE_RESOURCE_GROUP"
fi
echo "Output Directory: $OUTPUT_DIR"
echo "Output File: $output_file"

# --- Azure CLI Extension Check ---
echo "Checking for 'resource-graph' Azure CLI extension..."
if ! az extension show --name resource-graph &>/dev/null; then
    echo "Installing 'resource-graph' extension..."
    az extension add --name resource-graph --yes || {
        echo "ERROR: Failed to install 'resource-graph' Azure CLI extension." >&2
        exit 1
    }
    echo "'resource-graph' extension installed successfully."
else
    echo "'resource-graph' extension is already installed."
fi

# --- First Command: Get Maintenance Events ---
echo "Fetching planned maintenance events from Azure..."
first_query="ServiceHealthResources
     | where type =~ 'Microsoft.ResourceHealth/events'
     | extend eventType = properties.EventType, status = properties.Status
     | extend description = properties.Title, trackingId = properties.TrackingId
     | extend summary = properties.Summary, level = properties.Level
     | extend impact = properties.Impact
     | extend impactStartTime = todatetime(tolong(properties.ImpactStartTime)), impactMitigationTime = todatetime(tolong(properties.ImpactMitigationTime))
     | where eventType == 'PlannedMaintenance'
     | project subscriptionId, trackingId, eventType, status, summary, description, level, impactStartTime, impactMitigationTime, id, impact"

# Add resource group filter if specified also add global location as it can impact all resource groups
if [[ -n "${AZURE_RESOURCE_GROUP:-}" ]]; then
    first_query="$first_query | where resourceGroup == '${AZURE_RESOURCE_GROUP}' OR location == 'global'"
fi

echo "Executing first query to get maintenance events..."
if ! events_result=$(az graph query -q "$first_query" --subscriptions "$AZURE_RESOURCE_SUBSCRIPTION_ID" -o json); then
    echo "ERROR: Failed to retrieve planned maintenance events from Azure." >&2
    echo "[]" > "$output_file"
    exit 1
fi

# Save events to temporary file
echo "$events_result" | jq '.data' > "$events_temp_file"

# Check if we found any events
event_count=$(jq 'length' "$events_temp_file")
if [[ $event_count -eq 0 ]]; then
    echo "No planned maintenance events found for the specified scope."
    echo "[]" > "$output_file"
    rm -f "$events_temp_file"
    exit 0
fi

echo "Found $event_count maintenance events."

# --- Second Command: Get Impacted Resources ---
echo "Fetching resources impacted by maintenance events..."
second_query="ServiceHealthResources 
        | where type == 'microsoft.resourcehealth/events/impactedresources' 
        | extend TrackingId = split(split(id, '/events/', 1)[0], '/impactedResources', 0)[0] 
        | extend p = parse_json(properties) 
        | project subscriptionId, TrackingId, resourceName=p.resourceName, resourceType=p.resourceType, resourceGroup=p.resourceGroup, region=p.targetRegion, resourceId=p.targetResourceId, id"

# Add resource group filter if specified
if [[ -n "${AZURE_RESOURCE_GROUP:-}" ]]; then
    second_query="$second_query | where resourceGroup == '${AZURE_RESOURCE_GROUP}'"
fi

echo "Executing second query to get impacted resources..."
if ! resources_result=$(az graph query -q "$second_query" --subscriptions "$AZURE_RESOURCE_SUBSCRIPTION_ID" -o json); then
    echo "ERROR: Failed to retrieve impacted resources from Azure." >&2
    # Continue with just the events data
    cp "$events_temp_file" "$output_file"
    rm -f "$events_temp_file"
    exit 1
fi

# Save resources to temporary file
echo "$resources_result" | jq '.data' > "$resources_temp_file"

# --- Merge the Results ---
echo "Merging events and impacted resources data..."

# Using jq to merge the data and filter out events with no impacted resources
jq --slurpfile resources "$resources_temp_file" '
  map(
    . as $event |
    # Find resources matching this event
    ($resources[0] | map(select(.TrackingId == $event.trackingId))) as $matchingResources |
    # Only include events that have at least one impacted resource
    if ($matchingResources | length) > 0 then
      . + {
        impactedResources: $matchingResources
      }
    else
      empty  # Skip events with no impacted resources
    end
  )
' "$events_temp_file" > "$output_file"

# Check if any events with impacted resources were found
final_event_count=$(jq 'length' "$output_file")
echo "Found $final_event_count maintenance events with impacted resources."

if [[ $final_event_count -eq 0 ]]; then
    echo "No maintenance events with impacted resources found for the specified scope."
fi

# Clean up temporary files
rm -f "$events_temp_file" "$resources_temp_file"

echo "Results saved to $output_file"
echo "--- Azure Planned Maintenance Event Retrieval Finished ---"

exit 0