variable "aws_instance_type" {
  default = "t2.large"
}

variable "ami_name" {
  default = "java-k8-ami-stack-51"
}

variable "component" {
  default = "java-k8"
}

variable "aws_accounts" {
  type = list(string)
  default= ["612713811844", "720791945719", "139282550922", "184888967663", "182498323465"]
}

variable "ami_regions" {
  type = list(string)
  default =["us-east-1"]
}

variable "aws_region" {
  default = "us-east-1"
}


variable "REGION" {
  type    = string
  default = "us-east-1"
}

data "amazon-ami" "source_ami" {
  filters = {
    name                = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
    root-device-type    = "ebs"
    virtualization-type = "hvm"
  }
  most_recent = true
  owners      = ["099720109477"]   # Canonical
  region      = var.aws_region
}


# source blocks are generated from your builders; a source can be referenced in
# build blocks. A build block runs provisioners and post-processors on a
# source.


source "amazon-ebs" "amazon_ebs" {
  assume_role {
    role_arn     = "arn:aws:iam::182498323465:role/Engineer"
  }

  ami_name             = "${var.ami_name}"
  ami_regions          = var.ami_regions
  ami_users            = var.aws_accounts
  #ami_groups              = ["all"]
  snapshot_users       = var.aws_accounts
  encrypt_boot         = false
  instance_type        = var.aws_instance_type
  iam_instance_profile = "EC2BootstrapRole"

  region      = var.aws_region
  ssh_username = "ubuntu"
  ssh_pty     = true
  ssh_timeout = "5m"

  launch_block_device_mappings {
    delete_on_termination = true
    device_name           = "/dev/sda1"
    encrypted             = false
    volume_size           = 40
    volume_type           = "gp3"
  }

  #Replace source_ami with source_ami_filter
  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
    }
    owners      = ["099720109477"]  # Canonical
    most_recent = true
  }
}


build {
  sources = ["source.amazon-ebs.amazon_ebs"]

  # Upload setup script
  provisioner "file" {
    source      = "../scripts/javasetup.sh"
    destination = "/tmp/javasetup.sh"
  }

  # Upload DatabaseConfigActiviti.java
  provisioner "file" {
    source      = "../scripts/DatabaseConfigActiviti.java"
    destination = "/tmp/DatabaseConfigActiviti.java"
  }

  # Upload ActivitiEngineConfig.java
  provisioner "file" {
    source      = "../scripts/ActivitiEngineConfig.java"
    destination = "/tmp/ActivitiEngineConfig.java"
  }

  # Upload DatabaseConfigSupplyChain.java
  provisioner "file" {
    source      = "../scripts/DatabaseConfigSupplyChain.java"
    destination = "/tmp/DatabaseConfigSupplyChain.java"
  }

  # Upload ApplicationProperties.ini
  provisioner "file" {
    source      = "../scripts/ApplicationProperties.ini"
    destination = "/tmp/ApplicationProperties.ini"
  }

  # Upload pom.xml
  provisioner "file" {
    source      = "../scripts/pom.xml"
    destination = "/tmp/pom.xml"
  }

  # Upload Cloudwatch
  provisioner "file" {
    source      = "../scripts/java_cloudwatch.sh"
    destination = "/tmp/java_cloudwatch.sh"
  }

  provisioner "file" {
  source      = "k8selected_env.txt"
  destination = "/tmp/k8selected_env.txt"
  }

  # Run the setup script
  provisioner "shell" {
    inline = [
      "chmod +x /tmp/javasetup.sh",
      "sudo /tmp/javasetup.sh"
    ]
  }
}


