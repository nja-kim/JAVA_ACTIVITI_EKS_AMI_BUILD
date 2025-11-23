#!/bin/bash
set -x

echo "=== Installing dependencies ==="
sudo yum update -y
sudo yum install -y amazon-cloudwatch-agent

sudo yum install git -y
sudo yum install aws-cli -y

echo "Installing and running CloudWatch agent to collect Memory and Disk metrics"
ps aux | grep amazon-ssm-agent || echo "SSM agent not running!"

echo "Creating CloudWatch Agent"
echo "Installing CloudWatch Agent"
# Download and install CloudWatch agent
wget https://s3.amazonaws.com/amazoncloudwatch-agent/amazon_linux/amd64/latest/amazon-cloudwatch-agent.rpm
sudo rpm -U ./amazon-cloudwatch-agent.rpm


echo "Creating CloudWatch Agent configuration"
# Create the config directory if it doesn't exist

echo "=== Preparing CloudWatch Agent configuration ==="
sudo mkdir -p /opt/aws/amazon-cloudwatch-agent/etc

# Only using instance ID for this setup (no ASG)
# Get instance metadata using IMDSv2
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/dynamic/instance-identity/document | \
  grep region | awk -F\" '{print $4}')

ASG_NAME=$(aws autoscaling describe-auto-scaling-instances --region us-east-1 --instance-ids $INSTANCE_ID --query 'AutoScalingInstances[0].AutoScalingGroupName' --output text 2>/dev/null)


echo "INSTANCE_ID: $INSTANCE_ID"
echo "REGION: $REGION"
echo "ASG_NAME: $ASG_NAME"

# If AWS CLI fails or returns None/null, try alternative method
if [ "$ASG_NAME" = "None" ] || [ "$ASG_NAME" = "" ] || [ "$ASG_NAME" = "null" ]; then
    ASG_NAME=$(aws ec2 describe-tags --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=aws:autoscaling:groupName" --query 'Tags[0].Value' --output text 2>/dev/null)
fi


if [ "$ASG_NAME" != "None" ] && [ "$ASG_NAME" != "" ] && [ "$ASG_NAME" != "null" ]; then
    echo "Found ASG: $ASG_NAME"
    # Include ASG name - use /etc directory instead of /bin
    sudo tee /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json > /dev/null << EOF
{
  "metrics": {
    "metrics_collected": {
      "mem": {
        "measurement": ["mem_used_percent"],
        "metrics_collection_interval": 60
      },
      "disk": {
        "measurement": ["used_percent"],
        "metrics_collection_interval": 60,
        "resources": ["/"]
      }
    },
    "append_dimensions": {
      "AutoScalingGroupName": "$ASG_NAME",
      "InstanceId": "\${aws:InstanceId}"
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/messages",
            "log_group_name": "/java-k8-activiti/messages",
            "log_stream_name": "{instance_id}-messages",
            "timestamp_format": "%b %d %H:%M:%S"
          },
          {
            "file_path": "/var/log/cloud-init.log",
            "log_group_name": "/java-k8-activiti/cloud-init",
            "log_stream_name": "{instance_id}-cloud-init",
            "timestamp_format": "%Y-%m-%dT%H:%M:%SZ"
          },
          {
            "file_path": "/var/log/setup.log",
            "log_group_name": "/java-k8-activiti/setup",
            "log_stream_name": "{instance_id}-setup",
            "timestamp_format": "%Y-%m-%d %H:%M:%S"
          }
        ]
      }
    }
  }
}
EOF
else
    echo "No ASG detected, using instance ID only"

fi

# Start CloudWatch agent
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
  -s