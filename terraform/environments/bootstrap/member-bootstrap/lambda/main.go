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
	"github.com/aws/aws-sdk-go/service/iam"
)

// PagerDutyEvent represents the structure of the event to send to PagerDuty
type PagerDutyEvent struct {
	RoutingKey  string           `json:"routing_key"`
	EventAction string           `json:"event_action"`
	Payload     PagerDutyPayload `json:"payload"`
}

// PagerDutyPayload represents the payload of the PagerDuty event
type PagerDutyPayload struct {
	Summary       string                 `json:"summary"`
	Source        string                 `json:"source"`
	Severity      string                 `json:"severity"`
	CustomDetails map[string]interface{} `json:"custom_details"`
}

// getAccountAlias retrieves the AWS account alias.
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

// sendToPagerDuty sends an event to PagerDuty.
func sendToPagerDuty(event PagerDutyEvent) error {
	url := "https://events.pagerduty.com/v2/enqueue"
	payload, err := json.Marshal(event)
	if err != nil {
		return fmt.Errorf("failed to marshal PagerDuty event: %w", err)
	}

	req, err := http.NewRequest("POST", url, bytes.NewBuffer(payload))
	if err != nil {
		return fmt.Errorf("failed to create HTTP request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("failed to send HTTP request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusAccepted {
		return fmt.Errorf("received non-accepted response from PagerDuty: %s", resp.Status)
	}

	return nil
}

// handler processes the incoming SNS event and sends an alert to PagerDuty.
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
