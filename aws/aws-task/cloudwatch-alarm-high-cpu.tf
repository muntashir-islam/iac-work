# SNS Topic for Notifications
resource "aws_sns_topic" "cpu_alarm_sns_topic" {
  name = "cpu-alarm-sns-topic"
}

# SNS Subscription to Email
resource "aws_sns_topic_subscription" "cpu_alarm_sns_subscription" {
  topic_arn = aws_sns_topic.cpu_alarm_sns_topic.arn
  protocol  = "email"
  endpoint  = "your-email@example.com"  # Replace with your email address
}

# CloudWatch Alarm for CPU Utilization
resource "aws_cloudwatch_metric_alarm" "cpu_high_alarm" {
  alarm_name          = "cpu_utilization_high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 70  # Trigger alarm when CPU utilization exceeds 70%
  alarm_description   = "This metric monitors the CPU utilization for EC2 instances."
  dimensions = {
    InstanceId = aws_instance.your_instance.id  # Replace with the instance ID or use wildcards for ASGs
  }

  # Send notification to SNS when alarm is triggered
  alarm_actions = [aws_sns_topic.cpu_alarm_sns_topic.arn]

  # Optional: Add action when the alarm state goes back to OK
  ok_actions = [aws_sns_topic.cpu_alarm_sns_topic.arn]
}

# Output for SNS Topic ARN
output "sns_topic_arn" {
  value = aws_sns_topic.cpu_alarm_sns_topic.arn
}