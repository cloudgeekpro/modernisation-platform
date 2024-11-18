

# Variable to allow bucket selection
variable "buckets_to_protect" {
  description = <<EOF
    Enter the pre-existing bucket names you want to enable malware protection for.
    Bucket names must be separated by commas (e.g., bucket1,bucket2,bucket3).
    To enable for all buckets, list all bucket names here.
  EOF
  type        = string
  default     = "tests3scanningkf,mytestbucket976858"
}

# Define the list of buckets to protect
locals {
  bucket_list = toset(split(",", replace(trimspace(var.buckets_to_protect), " ", "")))
}

# # Local with the list of buckets to protect
# locals {
#   bucket_list = toset([
#     "tests3scanningkf",
#     "mytestbucket976858",
#   ])
# }



# Create KMS Key for Encryption and Decryption
resource "aws_kms_key" "malware_protection_key" {
  description = "KMS key for S3 malware protection"
  policy      = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EnableIAMUserPermissions",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
      },
      "Action": "kms:*",
      "Resource": "*"
    }
  ]
}
EOF
}

# Create IAM Role for GuardDuty Malware Protection
resource "aws_iam_role" "guardduty_role" {
  name               = "GuardDutyMalwareProtectionRole"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "malware-protection-plan.guardduty.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

# IAM Policy for GuardDuty Malware Protection Role
resource "aws_iam_policy" "guardduty_policy" {
  name        = "GuardDutyMalwareProtectionPolicy"
  description = "Policy for GuardDuty Malware Protection Plan"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowManagedRuleToSendS3EventsToGuardDuty",
      "Effect": "Allow",
      "Action": [
        "events:PutRule",
        "events:DeleteRule",
        "events:PutTargets",
        "events:RemoveTargets"
      ],
      "Resource": [
        "arn:aws:events:${var.region}:${data.aws_caller_identity.current.account_id}:rule/DO-NOT-DELETE-AmazonGuardDutyMalwareProtectionS3*"
      ],
      "Condition": {
        "StringLike": {
          "events:ManagedBy": "malware-protection-plan.guardduty.amazonaws.com"
        }
      }
    },
    {
      "Sid": "AllowGuardDutyToMonitorEventBridgeManagedRule",
      "Effect": "Allow",
      "Action": [
        "events:DescribeRule",
        "events:ListTargetsByRule"
      ],
      "Resource": [
        "arn:aws:events:${var.region}:${data.aws_caller_identity.current.account_id}:rule/DO-NOT-DELETE-AmazonGuardDutyMalwareProtectionS3*"
      ]
    },
    {
      "Sid": "AllowPostScanTag",
      "Effect": "Allow",
      "Action": [
        "s3:PutObjectTagging",
        "s3:GetObjectTagging",
        "s3:PutObjectVersionTagging",
        "s3:GetObjectVersionTagging"
      ],
      "Resource": [
        "arn:aws:s3:::*/*"
      ]
    },
    {
      "Sid": "AllowEnableS3EventBridgeEvents",
      "Effect": "Allow",
      "Action": [
        "s3:PutBucketNotification",
        "s3:GetBucketNotification"
      ],
      "Resource": [
        "arn:aws:s3:::*"
      ]
    },
    {
      "Sid": "AllowPutValidationObject",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject"
      ],
      "Resource": [
        "arn:aws:s3:::*/malware-protection-resource-validation-object"
      ]
    },
    {
      "Sid": "AllowCheckBucketOwnership",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::*"
      ]
    },
    {
      "Sid": "AllowMalwareScan",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion"
      ],
      "Resource": [
        "arn:aws:s3:::*/*"
      ]
    },
    {
     "Sid": "AllowDecryptForMalwareScan",
      "Effect": "Allow",
      "Action": [
        "kms:GenerateDataKey",
        "kms:Decrypt"
      ],
      "Resource": "${aws_kms_key.malware_protection_key.arn}",
      "Condition": {
        "StringLike": {
          "kms:ViaService": "s3.${var.region}.amazonaws.com"
        }
      }
    },
    {
      "Sid": "AllowPassAllRoles",
      "Effect": "Allow",
      "Action": [
        "iam:PassRole"
      ],
      "Resource": [
        "arn:aws:iam::*:role/*"
      ]
    }
  ]
}
EOF
}

# Attach Policy to the Role
resource "aws_iam_role_policy_attachment" "guardduty_role_policy_attach" {
  role       = aws_iam_role.guardduty_role.name
  policy_arn = aws_iam_policy.guardduty_policy.arn
}




# GuardDuty Malware Protection Plan
resource "aws_guardduty_malware_protection_plan" "malware_protection_plan" {
  for_each = local.bucket_list

  role = aws_iam_role.guardduty_role.arn

  protected_resource {
    s3_bucket {
      bucket_name = each.key
    }
  }


  actions {
    tagging {
      status = "ENABLED"
    }
  }

  tags = {
    "Name" = "GuardDutyMalwareProtectionPlan-${each.key}"  # Unique tag for each bucket
  }
}

# Variable for Region
variable "region" {
  default = "eu-west-2"
}
