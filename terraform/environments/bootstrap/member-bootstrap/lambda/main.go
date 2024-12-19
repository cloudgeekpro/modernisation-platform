package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/cloudtrail"
	"github.com/aws/aws-sdk-go/service/cloudwatchlogs"
	"github.com/aws/aws-sdk-go/service/iam"
)

type PagerDutyEvent struct {
	RoutingKey  string           `json:"routing_key"`
	EventAction string           `json:"event_action"`
	Payload     PagerDutyPayload `json:"payload"`
}

type PagerDutyPayload struct {
	Summary       string                 `json:"summary"`
	Source        string                 `json:"source"`
	Severity      string                 `json:"severity"`
	CustomDetails map[string]interface{} `json:"custom_details"`
}

// getAccountAlias retrieves the AWS account alias for the current session.
// Returns "NoAlias" if no alias is set or if there's an error.
func getAccountAlias(sess *session.Session) (string, error) {
	svc := iam.New(sess)
	result, err := svc.ListAccountAliases(&iam.ListAccountAliasesInput{})
	if err != nil {
		return "", err
	}
	if len(result.AccountAliases) > 0 {
		return aws.StringValue(result.AccountAliases[0]), nil
	}
	return "NoAlias", nil
}

// sendToPagerDuty sends a PagerDuty event to the PagerDuty API.
// Retries are handled by the caller function.
func sendToPagerDuty(event PagerDutyEvent) error {
	payloadBytes, err := json.Marshal(event)
	if err != nil {
		return fmt.Errorf("error marshaling PagerDuty event: %w", err)
	}

	req, err := http.NewRequest("POST", "https://events.pagerduty.com/v2/enqueue", bytes.NewBuffer(payloadBytes))
	if err != nil {
		return fmt.Errorf("error creating HTTP request: %w", err)
	}

	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("error sending request to PagerDuty: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		return fmt.Errorf("error from PagerDuty API: %s", resp.Status)
	}

	log.Printf("Successfully sent alert to PagerDuty: %s", resp.Status)
	return nil
}

// searchCloudTrailLogs searches for CloudTrail events near the time of the alarm.
// The filter pattern associated with the alarm is used to narrow down the results.
func searchCloudTrailLogs(sess *session.Session, alarmArn string, stateChangeTime string) (string, error) {
	ct := cloudtrail.New(sess)

	// Define the custom time layout for parsing the state change time.
	const customTimeLayout = "2006-01-02T15:04:05.000-0700"
	eventTime, err := time.Parse(customTimeLayout, stateChangeTime)
	if err != nil {
		return "", fmt.Errorf("failed to parse state change time: %v", err)
	}

	// Define the time range for querying CloudTrail logs.
	startTime := eventTime.Add(-10 * time.Minute)
	endTime := eventTime.Add(10 * time.Minute)

	// Retrieve the metric filter pattern associated with the alarm.
	metricFilter, err := getMetricFilter(sess, alarmArn)
	if err != nil {
		return "", fmt.Errorf("failed to get metric filter: %v", err)
	}

	filterPattern := aws.StringValue(metricFilter.FilterPattern)
	if filterPattern == "" {
		return "", fmt.Errorf("filter pattern is empty for alarm: %s", alarmArn)
	}

	log.Printf("Using filter pattern: %s", filterPattern)

	// Query CloudTrail logs using the defined time range.
	input := &cloudtrail.LookupEventsInput{
		StartTime: aws.Time(startTime),
		EndTime:   aws.Time(endTime),
	}

	result, err := ct.LookupEvents(input)
	if err != nil {
		return "", fmt.Errorf("failed to lookup CloudTrail events: %v", err)
	}

	// Parse the CloudTrail logs to extract the user identity.
	for _, event := range result.Events {
		var eventData map[string]interface{}
		if err := json.Unmarshal([]byte(*event.CloudTrailEvent), &eventData); err != nil {
			log.Printf("Failed to parse CloudTrail event: %v", err)
			continue
		}

		// Check if the event matches the filter pattern.
		if matchesFilterPattern(eventData, filterPattern) {
			if userIdentity, ok := eventData["userIdentity"].(map[string]interface{}); ok {
				if userName, ok := userIdentity["userName"].(string); ok {
					return userName, nil
				}
			}
		}
	}

	// Return "Unknown" if no matching user identity is found.
	return "Unknown", nil
}

// getMetricFilter retrieves the metric filter associated with the alarm's log group.
func getMetricFilter(sess *session.Session, alarmArn string) (*cloudwatchlogs.MetricFilter, error) {
	// Define the log group name directly as "cloudtrail".
	logGroupName := "cloudtrail"
	cwLogs := cloudwatchlogs.New(sess)

	// Fetch all metric filters for the specified log group.
	filters, err := cwLogs.DescribeMetricFilters(&cloudwatchlogs.DescribeMetricFiltersInput{
		LogGroupName: aws.String(logGroupName),
	})
	if err != nil {
		return nil, fmt.Errorf("failed to describe metric filters: %v", err)
	}
	if len(filters.MetricFilters) == 0 {
		return nil, fmt.Errorf("no metric filters found for log group: %s", logGroupName)
	}

	// Return the first metric filter found (assuming it's relevant).
	return filters.MetricFilters[0], nil
}

// matchesFilterPattern checks if a CloudTrail event matches the provided filter pattern.
func matchesFilterPattern(eventData map[string]interface{}, filterPattern string) bool {
	if eventName, ok := eventData["eventName"].(string); ok {
		return eventName == filterPattern
	}
	return false
}

// handler processes the incoming SNS event, searches CloudTrail, and sends an alert to PagerDuty.
func handler(ctx context.Context, snsEvent events.SNSEvent) error {
	// Initialize an AWS session.
	sess := session.Must(session.NewSession())

	// Get the AWS account alias.
	accountAlias, err := getAccountAlias(sess)
	if err != nil {
		log.Printf("Failed to retrieve account alias: %v", err)
		accountAlias = "Unknown"
	}

	// Process each SNS record.
	for _, record := range snsEvent.Records {
		snsMessage := record.SNS.Message
		log.Printf("Processing SNS message: %s", snsMessage)

		// Parse the SNS message into a structured format.
		var alarmDetails map[string]interface{}
		if err := json.Unmarshal([]byte(snsMessage), &alarmDetails); err != nil {
			log.Printf("Failed to parse SNS message: %v", err)
			continue
		}

		// Extract alarm details from the message.
		alarmName := alarmDetails["AlarmName"].(string)
		accountID := alarmDetails["AWSAccountId"].(string)
		alarmArn := alarmDetails["AlarmArn"].(string)
		alarmDescription := alarmDetails["AlarmDescription"].(string)
		newStateReason := alarmDetails["NewStateReason"].(string)
		newStateValue := alarmDetails["NewStateValue"].(string)
		stateChangeTime := alarmDetails["StateChangeTime"].(string)

		// Search CloudTrail logs to find the user identity.
		userIdentity, err := searchCloudTrailLogs(sess, alarmArn, stateChangeTime)
		if err != nil {
			log.Printf("Failed to search CloudTrail logs: %v", err)
			userIdentity = "Unknown"
		}

		// Build custom details for the PagerDuty event.
		customDetails := map[string]interface{}{
			"Account Name":      accountAlias,
			"AWS Account Id":    accountID,
			"Alarm Name":        alarmName,
			"Alarm Arn":         alarmArn,
			"Alarm Description": alarmDescription,
			"New State Reason":  newStateReason,
			"New State Value":   newStateValue,
			"State Change Time": stateChangeTime,
			"User Identity":     userIdentity,
		}

		// Construct the PagerDuty event.
		pagerDutyEvent := PagerDutyEvent{
			RoutingKey:  os.Getenv("PAGERDUTY_INTEGRATION_KEY"),
			EventAction: "trigger",
			Payload: PagerDutyPayload{
				Summary:       fmt.Sprintf("CloudWatch Alarm | %s | Account: %s (%s)", alarmName, accountAlias, accountID),
				Source:        fmt.Sprintf("AWS Account: %s (%s)", accountAlias, accountID),
				Severity:      "critical",
				CustomDetails: customDetails,
			},
		}

		// Send the event to PagerDuty with retries and exponential backoff.
		retries := 3
		for i := 0; i < retries; i++ {
			err := sendToPagerDuty(pagerDutyEvent)
			if err != nil {
				if i < retries-1 {
					log.Printf("Retrying to send alert to PagerDuty: attempt %d", i+2)
					time.Sleep(time.Duration(i+1) * time.Second)
					continue
				}
				log.Printf("Failed to send alert to PagerDuty after %d attempts: %v", retries, err)
			} else {
				break
			}
		}
	}

	return nil
}

// main is the entry point for the Lambda function.
func main() {
	lambda.Start(handler)
}
