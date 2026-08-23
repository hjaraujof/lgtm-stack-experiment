# =============================================================================
# Alerting: SNS topic + CloudWatch alarms + SNS-publish IAM
# =============================================================================
# These were originally created out-of-band via AWS CLI during the 2026-06/07
# incident response, then codified here and imported into state so `tofu plan`
# stays clean and the alerting infra is code-managed.
#
# Import commands (run once, then `tofu plan` must show no changes):
#   tofu import aws_sns_topic.lgtm_alerts arn:aws:sns:us-east-1:123456789012:lgtm-stack-alerts
#   tofu import aws_iam_role_policy.lgtm_sns_publish lgtm-ec2-instance-role:lgtm-sns-publish
#   tofu import 'aws_cloudwatch_metric_alarm.disk_warning' 'LGTM-Stack - Disk Space WARNING (75%)'
#   tofu import 'aws_cloudwatch_metric_alarm.disk_critical' 'LGTM-Stack - Disk Space CRITICAL (90%)'
#   tofu import 'aws_cloudwatch_metric_alarm.ec2_statuscheck' 'LGTM-Stack - EC2 StatusCheckFailed'
#   tofu import 'aws_cloudwatch_metric_alarm.telemetry_deadmans_switch' 'LGTM-Stack - Telemetry Dead Mans Switch'

locals {
  lgtm_alerts_topic_arn   = "arn:aws:sns:us-east-1:123456789012:lgtm-stack-alerts"
  lgtm_watchdog_topic_arn = "arn:aws:sns:us-east-1:123456789012:lgtm-watchdog"
}

resource "aws_sns_topic" "lgtm_alerts" {
  name = "lgtm-stack-alerts"
  tags = {
    project = "lgtm-stack-experiment"
    purpose = "disk-and-stack-alarms"
  }
  # Subscriptions (email to admin@, Teams) were added via CLI/console and are
  # intentionally NOT managed here to avoid churn; manage them out-of-band.
  lifecycle {
    ignore_changes = [policy, delivery_policy]
  }
}

# HEARTBEAT SINK for the Watchdog alert. DELIBERATELY HAS NO SUBSCRIPTIONS.
#
# The Watchdog rule in config/mimir/rules/demo/stack-alerts.yaml fires permanently and routes here
# through the sns-watchdog receiver in demo-am.yaml. Its only consumer is the CloudWatch alarm below,
# which counts publishes.
#
# DO NOT SUBSCRIBE ANYTHING TO THIS TOPIC, and do not point it at lgtm-stack-alerts. That turns the
# heartbeat into dozens of messages a day, somebody mutes the channel within a week, and the only
# out-of-band detector this stack has is gone.
resource "aws_sns_topic" "lgtm_watchdog" {
  name = "lgtm-watchdog"
  tags = {
    project = "lgtm-stack-experiment"
    purpose = "alert-delivery-heartbeat"
  }
  lifecycle {
    ignore_changes = [policy, delivery_policy]
  }
}

# Instance role may publish to BOTH topics: lgtm-stack-alerts (the Mimir Alertmanager's sns_configs)
# and lgtm-watchdog (the Watchdog heartbeat).
#
# KEEP THIS LIST IN STEP WITH THE RECEIVERS IN demo-am.yaml. Omitting a topic here makes the
# Alertmanager fail its publish with AccessDenied, and both directions of that mistake are silent:
# without lgtm-watchdog the heartbeat never leaves the box, which makes the alarm below fire
# PERMANENTLY instead of never — and a permanently-firing detector gets disabled, which is worse than
# not having one.
resource "aws_iam_role_policy" "lgtm_sns_publish" {
  name = "lgtm-sns-publish"
  role = aws_iam_role.lgtm_instance_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sns:Publish", "sns:GetTopicAttributes"]
      Resource = [local.lgtm_alerts_topic_arn, local.lgtm_watchdog_topic_arn]
    }]
  })
}

# THE REAL ALERT-DELIVERY DETECTOR, and the reason it lives out here in CloudWatch rather than in the
# rule files.
#
# AlertDeliverySilent and AlertmanagerConfigChanged are evaluated by the Mimir ruler and delivered by
# the Mimir Alertmanager. In the exact failure they describe — an Alertmanager that accepts alerts
# and dispatches none — THEY CANNOT BE DELIVERED. A detector that shares a failure domain with the
# thing it watches is not a detector.
#
# This alarm watches the Watchdog heartbeat's publish count on a path that does NOT traverse the
# Mimir Alertmanager at all, so it survives that failure. DO NOT DELETE IT in the belief that the
# in-stack alerts cover it.
#
# `treat_missing_data = "breaching"` IS LOAD-BEARING. SNS emits NO DATAPOINT AT ALL when a topic gets
# zero publishes, so "missing" IS the failure signal. Left at the default, this alarm sits in
# INSUFFICIENT_DATA through the entire outage and never fires — the same absent-series trap that
# defeats a bare `== 0` in PromQL, in a different system.
resource "aws_cloudwatch_metric_alarm" "alert_delivery_silent" {
  alarm_name          = "LGTM-Stack - Alert Delivery Silent"
  alarm_description   = "No Watchdog heartbeat on the lgtm-watchdog SNS topic for 3h. The Mimir Alertmanager has stopped dispatching, so EVERY LGTM alert is currently going nowhere. Runbook: docs/runbooks/alert-delivery-silent.md"
  namespace           = "AWS/SNS"
  metric_name         = "NumberOfMessagesPublished"
  dimensions          = { TopicName = aws_sns_topic.lgtm_watchdog.name }
  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [local.lgtm_alerts_topic_arn]
  ok_actions          = [local.lgtm_alerts_topic_arn]
}

# --- Disk alarms (Metrics Insights, dimension-agnostic so they survive instance resizes) ---
resource "aws_cloudwatch_metric_alarm" "disk_warning" {
  alarm_name          = "LGTM-Stack - Disk Space WARNING (75%)"
  alarm_description   = "LGTM EC2 (${aws_instance.lgtm_instance.id}) root disk >=75%. Metrics Insights (InstanceId-based) so it survives instance-type/resize changes."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 75
  treat_missing_data  = "breaching"
  alarm_actions       = [local.lgtm_alerts_topic_arn]
  ok_actions          = [local.lgtm_alerts_topic_arn]
  metric_query {
    id          = "disk75"
    period      = 300
    return_data = true
    expression  = "SELECT MAX(disk_used_percent) FROM \"LGTM/EC2\" WHERE InstanceId = '${aws_instance.lgtm_instance.id}' AND path = '/'"
  }
}

resource "aws_cloudwatch_metric_alarm" "disk_critical" {
  alarm_name          = "LGTM-Stack - Disk Space CRITICAL (90%)"
  alarm_description   = "LGTM EC2 (${aws_instance.lgtm_instance.id}) root disk >=90%. ACT NOW: at 100% SSM dies. Metrics Insights (InstanceId-based), survives resizes."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 90
  treat_missing_data  = "breaching"
  alarm_actions       = [local.lgtm_alerts_topic_arn]
  ok_actions          = [local.lgtm_alerts_topic_arn]
  metric_query {
    id          = "disk90"
    period      = 300
    return_data = true
    expression  = "SELECT MAX(disk_used_percent) FROM \"LGTM/EC2\" WHERE InstanceId = '${aws_instance.lgtm_instance.id}' AND path = '/'"
  }
}

# --- External failure detection (fire even if the whole host dies) ---
resource "aws_cloudwatch_metric_alarm" "ec2_statuscheck" {
  alarm_name          = "LGTM-Stack - EC2 StatusCheckFailed"
  alarm_description   = "LGTM EC2 failed an EC2 status check (host/instance impairment). The stack cannot alert on its own total failure - this catches it."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  dimensions          = { InstanceId = aws_instance.lgtm_instance.id }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [local.lgtm_alerts_topic_arn]
  ok_actions          = [local.lgtm_alerts_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "telemetry_deadmans_switch" {
  alarm_name          = "LGTM-Stack - Telemetry Dead Mans Switch"
  alarm_description   = "No LGTM/EC2 mem_used_percent datapoints = CloudWatch agent dead / host down / network partition. Dimension-agnostic Metrics Insights (survives resizes)."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 0
  treat_missing_data  = "breaching"
  alarm_actions       = [local.lgtm_alerts_topic_arn]
  ok_actions          = [local.lgtm_alerts_topic_arn]
  metric_query {
    id          = "dms"
    period      = 300
    return_data = true
    expression  = "SELECT AVG(mem_used_percent) FROM \"LGTM/EC2\" WHERE InstanceId = '${aws_instance.lgtm_instance.id}'"
  }
}
