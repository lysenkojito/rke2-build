terraform {
  backend "local" {
    path = "server.tfstate"
  }
    required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.67.0"
    }
  }
}

locals {
  name                      = var.name
  rke2_cluster_secret       = var.rke2_cluster_secret
  rke2_version              = var.rke2_version
}

provider "aws" {
  region  = "us-east-2"
  profile = var.aws_profile
}

resource "aws_security_group" "rke2-all-open" {
  name   = "${local.name}-sg"
  vpc_id = data.aws_vpc.rke2-vpc.id

  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "rke2-master-nlb" {
  name               = "${local.name}-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets = data.aws_subnet_ids.rke2-subnet-ids.ids
}

resource "aws_route53_record" "www" {
   # currently there is the only way to use nlb dns name in rke2
   # because the real dns name is too long and cause an issue
   zone_id = var.zone_id
   name = var.domain_name
   type = "CNAME"
   ttl = "30"
   records = ["${aws_lb.rke2-master-nlb.dns_name}"]
}

resource "aws_lb_target_group" "rke2-master-nlb-tg" {
  name     = "${local.name}-nlb-tg"
  port     = "6443"
  protocol = "TCP"
  vpc_id   = data.aws_vpc.rke2-vpc.id
  deregistration_delay = "300"
  health_check {
    interval = "30"
    port = "6443"
    protocol = "TCP"
    healthy_threshold = "10"
    unhealthy_threshold= "10"
  }
}

resource "aws_lb_listener" "rke2-master-nlb-tg" {
  load_balancer_arn = "${aws_lb.rke2-master-nlb.arn}"
  port              = "6443"
  protocol          = "TCP"
  default_action {
    target_group_arn = "${aws_lb_target_group.rke2-master-nlb-tg.arn}"
    type             = "forward"
  }
}

resource "aws_lb_target_group" "rke2-master-supervisor-nlb-tg" {
  name     = "${local.name}-nlb-supervisor-tg"
  port     = "9345"
  protocol = "TCP"
  vpc_id   = data.aws_vpc.rke2-vpc.id
  deregistration_delay = "300"
  health_check {
    interval = "30"
    port = "9345"
    protocol = "TCP"
    healthy_threshold = "10"
    unhealthy_threshold= "10"
  }
}

resource "aws_lb_listener" "rke2-master-supervisor-nlb-tg" {
  load_balancer_arn = "${aws_lb.rke2-master-nlb.arn}"
  port              = "9345"
  protocol          = "TCP"
  default_action {
    target_group_arn = "${aws_lb_target_group.rke2-master-supervisor-nlb-tg.arn}"
    type             = "forward"
  }
}

resource "aws_lb_target_group_attachment" "rke2-nlb-attachement" {
  count = var.server_count
  target_group_arn = "${aws_lb_target_group.rke2-master-nlb-tg.arn}"
  target_id        = "${aws_instance.rke2-server[count.index].id}"
  port             = 6443
}

resource "aws_lb_target_group_attachment" "rke2-nlb-supervisor-attachement" {
  count = var.server_count
  target_group_arn = "${aws_lb_target_group.rke2-master-supervisor-nlb-tg.arn}"
  target_id        = "${aws_instance.rke2-server[count.index].id}"
  port             = 9345
}

resource "aws_instance" "rke2-server" {
  count = var.server_count
  instance_type = var.server_instance_type
  ami           = data.aws_ami.ubuntu.id
  key_name      = var.ssh_keypair_name
  user_data     = base64encode(templatefile("${path.module}/files/server_userdata.tmpl",
  {
    extra_ssh_keys = var.extra_ssh_keys,
    rke2_cluster_secret = local.rke2_cluster_secret,
    rke2_version = local.rke2_version,
    rke2_server_args = var.rke2_server_args,
    lb_address = aws_lb.rke2-master-nlb.dns_name,
    domain_name = var.domain_name
    master_index = count.index,
    rke2_arch = var.rke2_arch,
    debug = var.debug,}))
  vpc_security_group_ids = [
    aws_security_group.rke2-all-open.id,
  ]

  root_block_device {
    volume_size = "30"
    volume_type = "gp2"
  }
  tags = {
    Name = "${local.name}-server-${count.index}"
    Role = "master"
    Leader = "${count.index == 0 ? "true" : "false"}"
  }
  provisioner "local-exec" {
      command = "sleep 10"
  }
  subnet_id = tolist(data.aws_subnet_ids.rke2-subnet-ids.ids)[count.index]
}

module "rke2-pool-agent-asg" {
  source        = "terraform-aws-modules/autoscaling/aws"
  version       = "6.9.0"
  name          = "${local.name}-pool"
  instance_type = var.agent_instance_type
  image_id      = data.aws_ami.ubuntu.id  
  max_size            = var.agent_node_count
  min_size            = var.agent_node_count
  vpc_zone_identifier = data.aws_subnet_ids.rke2-subnet-ids.ids
  security_groups = [
    aws_security_group.rke2-all-open.id,
  ]
  
  user_data     = base64encode(templatefile("${path.module}/files/agent_userdata.tmpl",
  {
    rke2_url = aws_lb.rke2-master-nlb.dns_name,
    extra_ssh_keys = var.extra_ssh_keys,
    rke2_cluster_secret = local.rke2_cluster_secret,
    rke2_version = local.rke2_version,
    rke2_agent_args = var.rke2_agent_args,
    lb_address = var.domain_name,
    rke2_arch = var.rke2_arch
    debug = var.debug,}))

  desired_capacity    = var.agent_node_count
  health_check_type   = "EC2"

  block_device_mappings = [
    {
      device_name = "/dev/xvda"
      no_device   = 0
      ebs = {
        delete_on_termination = true
        encrypted             = true
        volume_size           = 30
        volume_type           = "gp2"
      }
    }
  ]
}

resource "null_resource" "get-kubeconfig" {
  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "until ssh -o 'UserKnownHostsFile=/dev/null' -o 'StrictHostKeyChecking=no' -i ${var.ssh_key_path} ubuntu@${aws_instance.rke2-server[0].public_ip} 'sudo sed \"s/localhost/${var.domain_name}/g;s/127.0.0.1/${var.domain_name}/g\" /etc/rancher/rke2/rke2.yaml' >| ./kubeconfig.yaml; do sleep 5; done"
  }
}