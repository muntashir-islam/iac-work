provider "aws" {
  region = "us-east-1"
}

# Generate SSH keys
resource "tls_private_key" "ssh_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_file" "private_key" {
  content  = tls_private_key.ssh_key.private_key_pem
  filename = "${path.module}/bastion_private_key.pem"
}

resource "local_file" "public_key" {
  content  = tls_private_key.ssh_key.public_key_openssh
  filename = "${path.module}/bastion_public_key.pub"
}

# VPC
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "main_vpc"
  }
}

# Subnets
resource "aws_subnet" "subnets" {
  for_each = {
    public  = { cidr_block = "10.0.1.0/24", type = "public" }
    private = { cidr_block = "10.0.2.0/24", type = "private" }
  }

  vpc_id     = aws_vpc.main.id
  cidr_block = each.value.cidr_block

  tags = {
    Name = "${each.value.type}_subnet"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "main_igw"
  }
}

# NAT Gateway & EIP
resource "aws_eip" "nat_eip" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat_gw" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.subnets["public"].id
}

# Route Tables
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "public_rt"
  }
}

resource "aws_route_table_association" "public_rta" {
  subnet_id      = aws_subnet.subnets["public"].id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_gw.id
  }

  tags = {
    Name = "private_rt"
  }
}

resource "aws_route_table_association" "private_rta" {
  subnet_id      = aws_subnet.subnets["private"].id
  route_table_id = aws_route_table.private_rt.id
}

# Security Group for Bastion Host
resource "aws_security_group" "bastion_sg" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "bastion_sg"
  }
}

# Security Group for App Server
resource "aws_security_group" "app_sg" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "app_sg"
  }
}


# # App Server in Private Subnet
# resource "aws_instance" "app_server" {
#   ami           = "ami-0c55b159cbfafe1f0" # Replace with your desired AMI ID
#   instance_type = "t2.micro"
#   subnet_id     = aws_subnet.subnets["private"].id
#   key_name      = tls_private_key.ssh_key.key_name

#   security_groups = [aws_security_group.app_sg.id]

#   tags = {
#     Name = "app_server"
#   }

#   provisioner "local-exec" {
#     command = "chmod 400 ${local_file.private_key.filename}"
#   }
# }

# Launch Template for App Server
resource "aws_launch_template" "app_launch_template" {
  name_prefix   = "app-launch-template-"
  image_id      = "ami-0c55b159cbfafe1f0" # Replace with your desired AMI ID
  instance_type = "t2.micro"
  key_name      = tls_private_key.ssh_key.key_name

  network_interfaces {
    associate_public_ip_address = false
    subnet_id                   = aws_subnet.subnets["private"].id
    security_groups             = [aws_security_group.app_sg.id]
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 8
    }
  }

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y nginx
              systemctl start nginx
              systemctl enable nginx
              EOF

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "app_server"
    }
  }
}

# Auto Scaling Group for App Server
resource "aws_autoscaling_group" "app_asg" {
  desired_capacity     = 2
  max_size             = 5
  min_size             = 2
  launch_template {
    id      = aws_launch_template.app_launch_template.id
    version = "$Latest"
  }

  vpc_zone_identifier = [aws_subnet.subnets["private"].id]

  tag {
    key                 = "Name"
    value               = "app_server"
    propagate_at_launch = true
  }

  health_check_type         = "EC2"
  health_check_grace_period = 300

  lifecycle {
    create_before_destroy = true
  }
}

# Security Group for Load Balancer
resource "aws_security_group" "lb_sg" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "lb_sg"
  }
}

# Application Load Balancer
resource "aws_lb" "app_lb" {
  name               = "app-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb_sg.id]
  subnets            = [aws_subnet.subnets["public"].id]

  enable_deletion_protection = false

  tags = {
    Name = "app_lb"
  }
}

# Target Group for Nginx on Port 80
resource "aws_lb_target_group" "app_tg" {
  name     = "app-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 5
    unhealthy_threshold = 2
    matcher             = "200"
  }

  tags = {
    Name = "app_tg"
  }
}

# Listener for Load Balancer on Port 80
resource "aws_lb_listener" "app_lb_listener" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

# Attach Auto Scaling Group to Load Balancer Target Group
resource "aws_autoscaling_attachment" "asg_attachment" {
  autoscaling_group_name = aws_autoscaling_group.app_asg.name
  lb_target_group_arn    = aws_lb_target_group.app_tg.arn
}

# Bastion Host in Public Subnet
resource "aws_instance" "bastion_host" {
  ami           = "ami-0c55b159cbfafe1f0" # Replace with your desired AMI ID
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.subnets["public"].id
  key_name      = tls_private_key.ssh_key.key_name

  security_groups = [aws_security_group.bastion_sg.id]

  tags = {
    Name = "bastion_host"
  }

  provisioner "local-exec" {
    command = "chmod 400 ${local_file.private_key.filename}"
  }
}


# Create an SNS Topic
resource "aws_sns_topic" "cpu_alarm_topic" {
  name = "cpu-alarm-topic"
}

# Subscribe an Email to the SNS Topic
resource "aws_sns_topic_subscription" "email_subscription" {
  topic_arn = aws_sns_topic.cpu_alarm_topic.arn
  protocol  = "email"
  endpoint  = "email@xxx"  # Replace with email address
}

# CloudWatch Alarm for CPU Utilization > 70%
resource "aws_cloudwatch_metric_alarm" "cpu_high_alarm" {
  alarm_name          = "High-CPU-Usage-Alarm"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300  # Period in seconds (5 minutes)
  statistic           = "Average"
  threshold           = 70
  alarm_description   = "This alarm triggers when the average CPU utilization is greater than 70% for two consecutive periods."
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.app_asg.name
  }
  alarm_actions       = [aws_sns_topic.cpu_alarm_topic.arn]

  tags = {
    Name = "cpu_high_alarm"
  }
}

# Output SSH command for Bastion Host
output "bastion_ssh_command" {
  value = "ssh -i ${local_file.private_key.filename} ec2-user@${aws_instance.bastion_host.public_ip}"
}

# Output SSH command for App Server (via Bastion Host)
output "app_ssh_command" {
  value = "ssh -i ${local_file.private_key.filename} -o ProxyCommand='ssh -W %h:%p -i ${local_file.private_key.filename} ec2-user@${aws_instance.bastion_host.public_ip}' ec2-user@${aws_launch_template.app_launch_template.private_ip}"
}
