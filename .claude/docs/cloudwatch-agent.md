# CloudWatch agent on the EC2 host

Moved out of `.claude/CLAUDE.md` so it loads only when you read it.

## Overview

The EC2 instance runs the Amazon CloudWatch agent to collect host metrics and ship logs to CloudWatch. This is infrastructure-level observability that complements the LGTM application telemetry.

## What's monitored

| Category | Metrics/Logs | CloudWatch Location |
|----------|--------------|---------------------|
| **CPU** | usage_idle, usage_iowait, usage_user, usage_system | `LGTM/EC2` namespace |
| **Memory** | used_percent, available, total, used | `LGTM/EC2` namespace |
| **Disk** | used_percent, inodes_free/used/total | `LGTM/EC2` namespace |
| **Disk I/O** | io_time, write/read_bytes, writes/reads | `LGTM/EC2` namespace |
| **Network** | bytes_sent/recv, packets_sent/recv | `LGTM/EC2` namespace |
| **Swap** | swap_used_percent | `LGTM/EC2` namespace |
| **System Logs** | /var/log/messages | `/lgtm/ec2/system` log group |
| **Docker Daemon** | Docker daemon logs | `/lgtm/ec2/docker-daemon` log group |
| **Setup Logs** | user_data script output | `/lgtm/ec2/setup` log group |

`config/cloudwatch-agent-config.json` is the source of truth for this table.

## Configuration

- **Config file**: `config/cloudwatch-agent-config.json`
- **Collection interval**: 60 seconds
- **Log retention**: 14 days

## IAM

The instance role `lgtm-ec2-instance-role` carries:
- `CloudWatchAgentServerPolicy` - push metrics and logs to CloudWatch
- `AmazonSSMManagedInstanceCore` - SSM Session Manager, the only routine way onto the box (SSH port 22 is closed in `main.tf`)

## Troubleshooting the agent

Open a session through SSM first (see the `ec2-ssm-access` skill), then:

```bash
# Check agent status
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -m ec2 -a status

# View agent logs
sudo tail -f /opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log

# Restart agent with config
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

# Check if agent is running
sudo systemctl status amazon-cloudwatch-agent
```

## Viewing metrics in the AWS console

1. Go to **CloudWatch** > **Metrics** > **All metrics**
2. Select the **LGTM/EC2** namespace
3. Filter by InstanceId to see host metrics

## Viewing logs in the AWS console

1. Go to **CloudWatch** > **Log groups**
2. Look for log groups starting with `/lgtm/`
