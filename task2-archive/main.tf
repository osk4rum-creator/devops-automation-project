# ==========================================
# 1. TERRAFORM SETTINGS & AWS PROVIDER
# ==========================================
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "eu-central-1" # Frankfurt
}

# ==========================================
# 2. NETWORKING INFRASTRUCTURE (VPC)
# ==========================================

# Create the Virtual Private Cloud (VPC)
resource "aws_vpc" "main_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "Project-VPC"
  }
}

# Create an Internet Gateway to allow external traffic
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main_vpc.id

  tags = {
    Name = "Project-IGW"
  }
}

# Create a Public Subnet for the Frontend/Nginx server
resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "eu-central-1a"
  map_public_ip_on_launch = true # Automatically assigns a public IP

  tags = {
    Name = "Project-Public-Subnet"
  }
}

# Create a Public Route Table
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main_vpc.id

  route {
    cidr_block = "0.0.0.0/0" # Route all outbound internet traffic
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "Project-Public-RouteTable"
  }
}

# Associate the Public Subnet with the Public Route Table
resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

# ==========================================
# 3. SECURITY GROUPS (Firewalls)
# ==========================================

# Public Security Group for Frontend (Nginx)
resource "aws_security_group" "frontend_sg" {
  name        = "frontend-sg"
  description = "Allow public HTTP traffic and SSH"
  vpc_id      = aws_vpc.main_vpc.id

  # Inbound HTTP (Port 80) from anywhere
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Inbound SSH (Port 22) from anywhere
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Outbound traffic (Allow everything)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "Frontend-SG"
  }
}

# Private Security Group for Backend / Worker
resource "aws_security_group" "backend_sg" {
  name        = "backend-sg"
  description = "Allow internal traffic and SSH"
  vpc_id      = aws_vpc.main_vpc.id

  # Allow all internal communication inside the VPC
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/16"]
  }

  # Allow SSH from anywhere for provisioning access
  ingress {
    from_port   = 22
    to_port     = 22
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
    Name = "Backend-SG"
  }
}

# ==========================================
# 4. COMPUTE INSTANCES (EC2 Servers)
# ==========================================

# 1. Frontend / Nginx Server
resource "aws_instance" "frontend" {
  ami                    = "ami-0084a47cc718c111a" # Ubuntu 24.04 LTS in eu-central-1
  instance_type          = "t3.micro"              # Free-Tier eligible for Frankfurt
  subnet_id              = aws_subnet.public_subnet.id
  vpc_security_group_ids = [aws_security_group.frontend_sg.id]
  key_name               = "devops-project-key" 

  tags = {
    Name = "Project-Frontend"
  }
}

# 2. Backend Server
resource "aws_instance" "backend" {
  ami                    = "ami-0084a47cc718c111a"
  instance_type          = "t3.micro"              # Free-Tier eligible for Frankfurt
  subnet_id              = aws_subnet.public_subnet.id
  vpc_security_group_ids = [aws_security_group.backend_sg.id]
  key_name               = "devops-project-key"

  tags = {
    Name = "Project-Backend"
  }
}

# 3. Worker Server
resource "aws_instance" "worker" {
  ami                    = "ami-0084a47cc718c111a"
  instance_type          = "t3.micro"              # Free-Tier eligible for Frankfurt
  subnet_id              = aws_subnet.public_subnet.id
  vpc_security_group_ids = [aws_security_group.backend_sg.id]
  key_name               = "devops-project-key"

  tags = {
    Name = "Project-Worker"
  }
}

# ==========================================
# 5. AUTOMATED OUTPUT PIPELINES
# ==========================================

output "frontend_public_ip" {
  description = "The public IP address of the Frontend proxy server"
  value       = aws_instance.frontend.public_ip
}

output "backend_public_ip" {
  description = "The public IP address of the Backend application server"
  value       = aws_instance.backend.public_ip
}

output "worker_public_ip" {
  description = "The public IP address of the Worker execution server"
  value       = aws_instance.worker.public_ip
}