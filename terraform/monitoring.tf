resource "aws_cloudwatch_dashboard" "infrastructure" {
  dashboard_name = "${local.name_prefix}-infrastructure"

  dashboard_body = file("${path.module}/../monitoring/dashboard_infrastructure.json")
}

resource "aws_cloudwatch_dashboard" "application" {
  dashboard_name = "${local.name_prefix}-application"

  dashboard_body = file("${path.module}/../monitoring/dashboard_application.json")
}

# ──────────────────────────────────────────────
# Alarms — Infra
# ──────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "ecs_cpu_high" {
  alarm_name          = "${local.name_prefix}-ecs-cpu-high"
  alarm_description   = "ECS CPU utilization above 80% for 5 minutes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "5"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = "60"
  statistic           = "Average"
  threshold           = "80"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  dimensions = {
    ServiceName = aws_ecs_service.app.name
    ClusterName = aws_ecs_cluster.main.name
  }
  tags = { Name = "${local.name_prefix}-ecs-cpu" }
}

resource "aws_cloudwatch_metric_alarm" "ecs_memory_high" {
  alarm_name          = "${local.name_prefix}-ecs-memory-high"
  alarm_description   = "ECS memory utilization above 90% for 5 minutes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "5"
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = "60"
  statistic           = "Average"
  threshold           = "90"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  dimensions = {
    ServiceName = aws_ecs_service.app.name
    ClusterName = aws_ecs_cluster.main.name
  }
  tags = { Name = "${local.name_prefix}-ecs-memory" }
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${local.name_prefix}-alb-5xx"
  alarm_description   = "ALB returned 5XX errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "3"
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = "60"
  statistic           = "Sum"
  threshold           = "10"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
  }
  tags = { Name = "${local.name_prefix}-alb-5xx" }
}

resource "aws_cloudwatch_metric_alarm" "alb_target_unhealthy" {
  alarm_name          = "${local.name_prefix}-target-unhealthy"
  alarm_description   = "More than 1 unhealthy target in the ALB target group"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "5"
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = "60"
  statistic           = "Average"
  threshold           = "1"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  dimensions = {
    TargetGroup  = aws_lb_target_group.app.arn_suffix
    LoadBalancer = aws_lb.main.arn_suffix
  }
  tags = { Name = "${local.name_prefix}-unhealthy-hosts" }
}

# ──────────────────────────────────────────────
# Alarms — RDS
# ──────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  alarm_name          = "${local.name_prefix}-rds-cpu-high"
  alarm_description   = "RDS CPU utilization above 75% for 10 minutes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "5"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = "120"
  statistic           = "Average"
  threshold           = "75"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  dimensions = {
    DBClusterIdentifier = aws_rds_cluster.main.cluster_identifier
  }
  tags = { Name = "${local.name_prefix}-rds-cpu" }
}

resource "aws_cloudwatch_metric_alarm" "rds_free_storage_low" {
  alarm_name          = "${local.name_prefix}-rds-storage-low"
  alarm_description   = "RDS free storage below 15% for 10 minutes"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "5"
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = "120"
  statistic           = "Average"
  threshold           = "2147483648"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  dimensions = {
    DBClusterIdentifier = aws_rds_cluster.main.cluster_identifier
  }
  tags = { Name = "${local.name_prefix}-rds-storage" }
}

resource "aws_cloudwatch_metric_alarm" "rds_connections_high" {
  alarm_name          = "${local.name_prefix}-rds-connections-high"
  alarm_description   = "RDS database connections above 100 for 5 minutes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "3"
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = "300"
  statistic           = "Average"
  threshold           = "100"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  dimensions = {
    DBClusterIdentifier = aws_rds_cluster.main.cluster_identifier
  }
  tags = { Name = "${local.name_prefix}-rds-conn" }
}

# ──────────────────────────────────────────────
# SNS for Alerts
# ──────────────────────────────────────────────
resource "aws_sns_topic" "alerts" {
  name = "${local.name_prefix}-alerts"

  tags = { Name = "${local.name_prefix}-alerts" }
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_sns_topic_subscription" "alerts_slack" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "https"
  endpoint  = var.slack_webhook_url
}

# ──────────────────────────────────────────────
# Log Metric Filters & Alarms
# ──────────────────────────────────────────────
resource "aws_cloudwatch_log_metric_filter" "app_errors" {
  name           = "${local.name_prefix}-app-errors"
  pattern        = "\"level\":\"error\""
  log_group_name = aws_cloudwatch_log_group.app.name

  metric_transformation {
    name      = "ApplicationErrorCount"
    namespace = "kayaka/logs"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "app_errors_high" {
  alarm_name          = "${local.name_prefix}-app-errors-high"
  alarm_description   = "High number of application errors in logs"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "5"
  metric_name         = "ApplicationErrorCount"
  namespace           = "kayaka/logs"
  period              = "60"
  statistic           = "Sum"
  threshold           = "10"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  tags                = { Name = "${local.name_prefix}-app-errors" }
}