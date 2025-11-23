#!/bin/bash

set -ex
KUBE_VERSION="${KUBE_VERSION:-1.30}"
AWS_REGION="us-east-1"
POD_CIDR="10.244.0.0/16"

CLUSTER_NAME="java-activiti-cluster"
AUTO_ECR_IMAGE_URI="182498323465.dkr.ecr.us-east-1.amazonaws.com/java-k8-activiti-repository:activiti-img-1.0"
DEV_ECR_IMAGE_URI="612713811844.dkr.ecr.us-east-1.amazonaws.com/java-k8-activiti-repository:activiti-img-1.0"
TEST_ECR_IMAGE_URI="720791945719.dkr.ecr.us-east-1.amazonaws.com/java-k8-activiti-repository:activiti-img-1.0"
UAT_ECR_IMAGE_URI="139282550922.dkr.ecr.us-east-1.amazonaws.com/java-k8-activiti-repository:activiti-img-1.0"
PROD_ECR_IMAGE_URI="184888967663.dkr.ecr.us-east-1.amazonaws.com/java-k8-activiti-repository:activiti-img-1.0"

REPO_NAME="java-k8-activiti-repository"
AVAILABILITY_ZONE=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
REGION=${AVAILABILITY_ZONE:0:-1}

sudo apt-get update -y

HOSTNAME=$(hostname)
echo "==========Setting hostname to ${MY_HOSTNAME}..."
printf '%s\n' "${MY_HOSTNAME}" > /etc/hostname
echo "127.0.1.1   ${MY_HOSTNAME}" | sudo tee -a /etc/hosts > /dev/null

# sudo hostnamectl set-hostname ${MY_HOSTNAME}
sudo hostnamectl set-hostname "${MY_HOSTNAME}" || sudo hostname -F /etc/hostname

# Add both hostnames to 127.0.0.1 line, removing any duplicates first
sudo sed -i "/^127\.0\.0\.1/{
    s/\b${HOSTNAME}\b//g;
    s/$/ ${HOSTNAME} ${MY_HOSTNAME}/
}" /etc/hosts

# Optionally print to confirm
echo "Hostname set to $(hostname)"

#################################
#------Fix DNS Resolution--------
#################################
sudo systemctl stop systemd-resolved
sudo systemctl disable systemd-resolved
sudo rm -f /etc/resolv.conf
echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf > /dev/null

echo "================================================================="
echo "---------------Installing AWS CLI -------------"
echo "================================================================="
sudo apt-get update -y
sudo apt install -y unzip
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -o awscliv2.zip
sudo ./aws/install
rm -rf awscliv2.zip aws/
aws --version

#--- Install GitHub
sudo apt install git -y

echo "================================================================="
echo "---------------Installing Docker-------------"
echo "================================================================="

sudo apt-get update -y
sudo apt install -y apt-transport-https ca-certificates curl software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update -y
sudo apt install -y docker-ce docker-ce-cli containerd.io
sudo docker --version
sudo usermod -aG docker ubuntu
# newgrp docker # DO NOT run newgrp inside Packer – it hangs forever

echo "================================================================="
echo "---------------System Config Modification-------------"
echo "================================================================="

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

echo "================================================================="
echo "---------------Disable Swap-------------"
echo "================================================================="

sudo swapoff -a || true
sudo sed -i.bak '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab || true

echo "================================================================="
echo "---------------Configure Containerd-------------"
echo "================================================================="

sudo cp /etc/containerd/config.toml /etc/containerd/config.toml.bak 2>/dev/null || true
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd

echo "===============-=================================================="
echo "---------------Install Kubernetes------------"
echo "================================================================="

echo "---------------Installing Kubernetes ${KUBE_VERSION}-------------"
sudo apt-get update -y
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/deb/Release.key" | \
  gpg --dearmor | sudo tee /etc/apt/keyrings/kubernetes-apt-keyring.gpg > /dev/null
  
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/deb/ /" | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update -y
echo "Fixing CNI conflict..."
sudo apt-get remove -y cnitool-plugins containerd.io || true
sudo apt-get autoremove -y || true

sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable kubelet

#  1) Install OpenJDK 8
echo "Installing OpenJDK 8..."
sudo apt-get update -y
sudo apt install -y openjdk-8-jdk

sudo readlink -f $(which java)
sudo readlink -f $(which javac)

# 2) Create Tomcat user and group
echo "Creating Tomcat user..."
sudo useradd -m -U -d /usr/local/tomcat -s /bin/false tomcat || echo "Tomcat user already exists."

# 3) Install wget and download Tomcat
echo "Downloading Apache Tomcat 9.0.33..."
sudo apt-get update -y
sudo apt install -y wget || true
cd /tmp

curl -O https://archive.apache.org/dist/tomcat/tomcat-9/v9.0.33/bin/apache-tomcat-9.0.33.tar.gz


# 4) Extract Tomcat package to /tmp
echo "Extracting Tomcat archive..."
cd /tmp
tar -xf apache-tomcat-9.0.33.tar.gz | head

# 5) Move to /usr/local/tomcat
echo "Moving Tomcat to /usr/local/tomcat..."
sudo mkdir -p /usr/local/tomcat
sudo mv /tmp/apache-tomcat-9.0.33 /usr/local/tomcat/

# 6) Create symbolic link for "latest"
echo "Creating symbolic link..."
sudo ln -sfn /usr/local/tomcat/apache-tomcat-9.0.33 /usr/local/tomcat/latest

# 7) Change ownership
echo "Setting tomcat permissions..."
sudo chown -R tomcat: /usr/local/tomcat

# 8) Make scripts executable
echo "Making bin scripts executable..."
sudo sh -c 'chmod +x /usr/local/tomcat/latest/bin/*.sh'

# 9) Create systemd service file
sudo tee /etc/systemd/system/tomcat.service > /dev/null <<EOF
[Unit]
Description=Apache Tomcat 9 Web Application Container
After=network.target

[Service]
Type=forking
User=tomcat
Group=tomcat

Environment=JAVA_HOME=/usr/lib/jvm/java-1.8.0-openjdk
Environment=CATALINA_HOME=/usr/local/tomcat/latest
Environment=CATALINA_BASE=/usr/local/tomcat/latest
Environment=CATALINA_PID=/usr/local/tomcat/latest/temp/tomcat.pid
Environment='CATALINA_OPTS=-Xms512M -Xmx1024M -server -XX:+UseParallelGC'
Environment='JAVA_OPTS=-Djava.awt.headless=true -Djava.security.egd=file:/dev/./urandom'
Environment=PATH=/usr/lib/jvm/java-1.8.0-openjdk/bin:/usr/local/tomcat/latest/bin:/usr/bin:/bin

ExecStart=/usr/local/tomcat/latest/bin/startup.sh start
ExecStop=/usr/local/tomcat/latest/bin/shutdown.sh stop

Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# Enable and start Tomcat
sudo systemctl daemon-reload
sudo systemctl enable tomcat
sudo systemctl start tomcat

echo "=== Tomcat installation completed successfully! ==="

# 15) Under the ubuntu, create an “apps” folder, then git clone the activity app
cd ~
sudo mkdir /home/ubuntu/apps
cd /home/ubuntu/apps
sudo apt-get update -y
sudo apt install git -y
sudo apt install maven -y
which git
which mvn


if git clone https://github.com/stackitgit/Activiti.git
then
  echo "Cloned as current user: $USER"
else
  echo "Clone failed as $USER — retrying as ubuntu..."
  sudo -u ubuntu git clone https://github.com/stackitgit/Activiti.git || {
    echo "Failed to clone even as ubuntu. Exiting."
    exit 1
  }
fi

# 16)	Install mysql database
# Ensure repo metadata is up to date
sudo apt clean || true
sudo apt autoclean || true

#--------install MariaDB
sudo apt update
sudo apt-get update -y
sudo apt install -y mariadb-server
sudo systemctl enable mariadb
sudo systemctl start mariadb

# lines 17 and 18 in activiti-app.properties need to be updated: username=javauser password=stackinc
# sudo sed -i 's/^datasource\.username=.*/datasource.username=javauser/; s/^datasource\.password=.*/datasource.password=stackinc/' /home/ec2-user/apps/Activiti/src/main/resources/META-INF/activiti-app/activiti-app.properties
sudo sed -i \
  -e 's/^datasource\.username=.*/datasource.username=javauser/' \
  -e 's/^datasource\.password=.*/datasource.password=stackinc/' \
  /home/ubuntu/apps/Activiti/src/main/resources/META-INF/activiti-app/activiti-app.properties || {
    echo "sed failed! Exiting."
    exit 1
}

# ==========================================================
# 18) Create the act6 database and users (local MariaDB)
# ==========================================================
sudo mysqladmin -u root password 'stackinc' || true
mysql -u root -pstackinc <<EOF
-- List existing databases
SHOW DATABASES;

-- Create the app database
CREATE DATABASE IF NOT EXISTS act6;

-- Create users (if not already created)
CREATE USER IF NOT EXISTS 'javauser'@'localhost' IDENTIFIED BY 'stackinc';
CREATE USER IF NOT EXISTS 'wordpressuser'@'localhost' IDENTIFIED BY 'W3lcome123';

-- Grant privileges
GRANT ALL PRIVILEGES ON act6.* TO 'javauser'@'localhost';
GRANT ALL PRIVILEGES ON act6.* TO 'wordpressuser'@'localhost';

-- Apply changes
FLUSH PRIVILEGES;
EOF

# ==========================================================
# 19) Perform Maven build (Activiti creates schema in act6)
# ==========================================================
cd /home/ubuntu/apps/Activiti
# Automatically set default java and javac to JDK 1.8 (in poc, it was option 1)
echo "=== Configuring Amazon Corretto 8 as default Java ==="

# Detect JAVA_HOME
JAVA_PATH=$(dirname $(dirname $(readlink -f $(which javac))))
echo "Detected JAVA_HOME as: $JAVA_PATH"

# Register Java with update-alternatives (Ubuntu)
sudo update-alternatives --install /usr/bin/java java $JAVA_PATH/bin/java 1
sudo update-alternatives --install /usr/bin/javac javac $JAVA_PATH/bin/javac 1

sudo update-alternatives --set java $JAVA_PATH/bin/java
sudo update-alternatives --set javac $JAVA_PATH/bin/javac

# Persist JAVA_HOME
sudo tee /etc/profile.d/java8.sh > /dev/null <<EOF
export JAVA_HOME=$JAVA_PATH
export PATH=\$JAVA_HOME/bin:\$PATH
EOF

# Reload for current session and verify
source /etc/profile.d/java8.sh

echo "Verifying Java and Maven setup..."
java -version
mvn -version
sudo apt-get update -y
sudo mvn clean install

# 20) target dir has been created
sudo cp target/activiti-app.war /usr/local/tomcat/latest/webapps/
sudo ls /usr/local/tomcat/latest/webapps/
sudo chown -R ubuntu:ubuntu /home/ubuntu/apps/Activiti

#Ensure working directory is ~/apps/Activiti
cd /home/ubuntu/apps/Activiti
sudo wget https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/8.0.33/mysql-connector-j-8.0.33.jar -P /home/ubuntu/apps/Activiti/lib/

echo "Creating a Dockerfile"
##################################################
#-------Dockerfile in ~/apps/Activiti
##################################################
cat <<'EOF' | sudo tee /home/ubuntu/apps/Activiti/Dockerfile > /dev/null
# ======== Base Build Stage ========
FROM maven:3.9.9-eclipse-temurin-8 AS builder
WORKDIR /app

COPY pom.xml .
RUN mvn dependency:go-offline -B

RUN apt-get update && apt-get install -y default-mysql-client

COPY . .
RUN mvn clean package -DskipTests


# ======== Runtime Stage ========
# FROM tomcat:9.0.89-jdk8-temurin
FROM tomcat:9.0.33-jdk8-openjdk

LABEL app="activiti-app" version="1.0" maintainer="you@example.com"

WORKDIR /usr/local/tomcat

# Set environment variables for DB (optional usage in config files)
ENV LANG=C.UTF-8 TZ=UTC \
    DB_HOST=localhost \
    DB_PORT=3306 \
    DB_NAME=act6 \
    DB_USER=wordpressuser \
    DB_PASS=W3lcome123

#  Inject JVM option to disable schema update for Activiti Form Engine
#ENV CATALINA_OPTS="-Dactiviti.formengine.update-schema=false"

# JDBC Driver
COPY lib/mysql-connector-j-8.0.33.jar /usr/local/tomcat/lib/

# WAR Deployment
COPY --from=builder /app/target/activiti-app.war webapps/activiti-app.war

# Unpack WAR and fix properties path
# --- Unpack WAR and flatten properties file path ---
# RUN set -ex && \
#     unzip -q webapps/activiti-app.war -d webapps/activiti-app && \
#     # Safe mkdir -p ensures no failure if directory exists
#     mkdir -p /usr/local/tomcat/webapps/activiti-app/WEB-INF/classes/META-INF/ && \
#     if [ -f /usr/local/tomcat/webapps/activiti-app/WEB-INF/classes/META-INF/activiti-app/activiti-app.properties ]; then \
#       echo "Found nested activiti-app.properties — flattening to META-INF/"; \
#       cp /usr/local/tomcat/webapps/activiti-app/WEB-INF/classes/META-INF/activiti-app/activiti-app.properties \
#          /usr/local/tomcat/webapps/activiti-app/WEB-INF/classes/META-INF/activiti-app.properties && \
#       rm -rf /usr/local/tomcat/webapps/activiti-app/WEB-INF/classes/META-INF/activiti-app; \
#     else \
#       echo "⚠️ activiti-app.properties not found in nested META-INF/activiti-app path"; \
#       ls -R /usr/local/tomcat/webapps/activiti-app/WEB-INF/classes/META-INF/ || true; \
#     fi

##################################################
# ======== Fix activiti-app.properties structure ========
# (Unpack WAR, patch datasource.url, remove WAR)
##################################################
RUN set -ex && \
    echo "🧱 Starting WAR unpack and DB config patch..." && \
    unzip -q webapps/activiti-app.war -d webapps/activiti-app && \
    META_PATH="/usr/local/tomcat/webapps/activiti-app/WEB-INF/classes/META-INF" && \
    NESTED_PATH="${META_PATH}/activiti-app" && \
    mkdir -p "${NESTED_PATH}" && \
    PROP_FILE="${NESTED_PATH}/activiti-app.properties" && \
    \
    # --- Update datasource.url dynamically using build-time DB_HOST (placeholder for ECS) ---
    if [ -f "${PROP_FILE}" ]; then \
        echo "🧩 Updating datasource.url with DB_HOST=${DB_HOST}"; \
        sed -i "s|^datasource.url=.*|datasource.url=jdbc:mysql://${DB_HOST}:3306/act6?useSSL=false\\&allowPublicKeyRetrieval=true\\&serverTimezone=UTC|" "${PROP_FILE}"; \
        echo "✅ Patched datasource.url:"; \
        grep datasource.url "${PROP_FILE}"; \
    else \
        echo "⚠️ activiti-app.properties not found at expected path; listing structure:"; \
        find "${META_PATH}" -type f -name activiti-app.properties || true; \
    fi && \
    \
    # --- Prevent Tomcat from redeploying and overwriting our patched app ---
    echo "🧹 Removing WAR so Tomcat won't re-explode it at startup" && \
    rm -f /usr/local/tomcat/webapps/activiti-app.war && \
    \
    # --- Verify structure ---
    echo "✅ Final structure after patch:" && \
    find "${META_PATH}" -maxdepth 3 -type f -name "activiti-app.properties"

# Change Tomcat default port from 8080 to 9090
RUN sed -i 's/port="8080"/port="80"/' conf/server.xml

EXPOSE 80

# JVM & Activiti settings
ENV CATALINA_OPTS="\
-Dactiviti.formengine.update-schema=false \
-Dspring.liquibase.enabled=false \
-Dactiviti.dmn.engine.update-schema=false \
-Dliquibase.scan.packages=liquibase.change,liquibase.changelog,liquibase.database,liquibase.parser,liquibase.precondition,liquibase.datatype,liquibase.serializer,liquibase.sqlgenerator,liquibase.executor,liquibase.snapshot,liquibase.logging,liquibase.diff,liquibase.structure,liquibase.structurecompare,liquibase.lockservice,liquibase.ext \
-Dspring.main.lazy-initialization=true"


# Run Tomcat with the updated JVM flags
ENTRYPOINT /bin/bash -c '\
  PROP_FILE="/usr/local/tomcat/webapps/activiti-app/WEB-INF/classes/META-INF/activiti-app/activiti-app.properties"; \
  echo "ENTRYPOINT running, DB_HOST=${DB_HOST}"; \
  for i in $(seq 1 60); do \
    if [ -f "$PROP_FILE" ]; then \
      echo "Found properties file at attempt $i"; break; \
    fi; \
    echo "⏳ Waiting for WAR extraction ($i)..."; sleep 2; \
  done; \
  if [ -f "$PROP_FILE" ]; then \
    echo "Updating datasource.url to use ${DB_HOST}"; \
    sed -i "s|^datasource.url=.*|datasource.url=jdbc:mysql://${DB_HOST}:3306/act6?useSSL=false\\&allowPublicKeyRetrieval=true\\&serverTimezone=UTC|" "$PROP_FILE"; \
  else \
    echo "File not found, skipping sed update"; \
  fi; \
  exec catalina.sh run'

# CMD ["sh", "-c", "echo 'CATALINA_OPTS => ' $CATALINA_OPTS && catalina.sh run"]
EOF

##########################################
#------------RDS
###########################################
# Import the Activiti engine schema
cd /home/ubuntu/apps/Activiti
mysqldump -u root -pstackinc act6 --no-data > act6_structure.sql
ls -lh act6_structure.sql || echo "Schema dump failed."

########################
#----sudo vi src/main/java/org/activiti/app/conf/DatabaseConfiguration.java - needs created then updated
########################
echo "Creating DB Activiti Java absolute path"
# --- Ensure Activiti conf folder exists ---
sudo mkdir -p /home/ubuntu/apps/Activiti/src/main/java/org/activiti/app/conf

# --- Copy DatabaseConfigActiviti.java into Activiti source tree ---$(dirname "${BASH_SOURCE[0]}") → finds the directory where setup.sh itself lives, no matter where the script is executed from.
sudo cp "/tmp/DatabaseConfigActiviti.java" \
    /home/ubuntu/apps/Activiti/src/main/java/org/activiti/app/conf/DatabaseConfiguration.java
echo "Successfully created the DB Activiti Config file"

########################
#---sudo vi src/main/java/supplychain/activiti/conf/DatabaseConfiguration.java : exists but needs updated. easier to update entire file
########################
if [ ! -f /tmp/DatabaseConfigSupplyChain.java ]
then
  echo "File not found: /tmp/DatabaseConfigSupplyChain.java"
  ls -l /tmp/DatabaseConfigSupplyChain.java || echo "Missing!"
  exit 1
fi

sudo cp "/tmp/DatabaseConfigSupplyChain.java" /home/ubuntu/apps/Activiti/src/main/java/supplychain/activiti/conf/DatabaseConfiguration.java

############################
#-----------sudo vi src/main/java/supplychain/activiti/conf/MyApplicationConfiguration.java : edit Component scan section
############################
APP_CONF="/home/ubuntu/apps/Activiti/src/main/java/supplychain/activiti/conf/MyApplicationConfiguration.java"

# Delete old lines 26–32 (inclusive)
sudo sed -i '26,32d' "$APP_CONF"

# Insert new @ComponentScan block starting at line 26
sudo sed -i '26i\
@ComponentScan(\
        basePackages = {\
                "com.zbq",\
                "supplychain.*",\
                "org.activiti.app.repository",\
                "org.activiti.app.service",\
                "org.activiti.app.security",\
                "org.activiti.app.model.component"\
        },\
        excludeFilters = @ComponentScan.Filter(\
                type = FilterType.REGEX,\
                pattern = "org\\\\.activiti\\\\.app\\\\.conf\\\\.DatabaseConfiguration"\
        )\
)' "$APP_CONF"

echo "Final content of $APP_CONF:"
sudo cat -n "$APP_CONF"

###################################3
#-----sudo vi src/main/resources/META-INF/activiti-app/activiti-app.properties - update db creds and add db update schema info after replatform
####################################
sudo cp "/tmp/ApplicationProperties.ini" \
    /home/ubuntu/apps/Activiti/src/main/resources/META-INF/activiti-app/activiti-app.properties

###############################
#---sudo vi src/main/java/supplychain/activiti/conf/ActivitiEngineConfiguration.java
##################################
sudo cp "/tmp/ActivitiEngineConfig.java" \
    /home/ubuntu/apps/Activiti/src/main/java/supplychain/activiti/conf/ActivitiEngineConfiguration.java

#################################3
#---- sudo vi pom.xml
#################################
if [ ! -f /tmp/pom.xml ]
then
  echo "File not found: /tmp/DatabaseConfigSupplyChain.java"
  ls -l /tmp/pom.xml|| echo "Missing!"
  exit 1
fi
sudo cp "/tmp/pom.xml" \
    /home/ubuntu/apps/Activiti/pom.xml

#------AUTO ACC---------
cd /home/ubuntu/apps/Activiti/
sudo docker build -t activiti-app:latest .

echo "Tagging image as ${AUTO_ECR_IMAGE_URI}"
sudo docker tag activiti-app:latest ${AUTO_ECR_IMAGE_URI}
sudo docker ps
sudo docker images

###########################################################
# --- STEP 2: Ensure Repo Exists in Automation Account ---
###########################################################
echo "🔹 Checking Automation ECR repository..."
if aws ecr describe-repositories --repository-names "${REPO_NAME}" --region "${REGION}" >/dev/null 2>&1
then
  echo "Repo ${REPO_NAME} exists in Automation account. Deleting..."
  aws ecr delete-repository --repository-name "${REPO_NAME}" --region "${REGION}" --force
  echo "Deleted old repo ${REPO_NAME}"
fi

echo "🔹 Creating new ECR repo in Automation account..."
aws ecr create-repository --repository-name "${REPO_NAME}" --region "${REGION}" >/dev/null
echo "Repo created successfully."

# ================================================
#   AUTO ACCOUNT: Creating Repo and Pushing Image
# ================================================

#--ECR Login
echo "Logging into ECR..."
sudo aws ecr get-login-password --region "${REGION}" | sudo docker login --username AWS --password-stdin "${AUTO_ECR_REGISTRY}"

#--Docker push
sudo docker push ${AUTO_ECR_IMAGE_URI}
echo "Pushed ${AUTO_ECR_IMAGE_URI} to Auto ECR"

# ================================================
#   Creating Policy: Allow cross-account pull and push
# ================================================

#--Attach cross-account policy
DEV_ACCOUNT_ID="612713811844"
TEST_ACCOUNT_ID="720791945719"
UAT_ACCOUNT_ID="139282550922"
PROD_ACCOUNT_ID="184888967663"

#--Attach cross-account policy (only if no policy exists)

echo "Creating ECR policy"

cat > /tmp/ecr-policy.json <<EOF
{
  "Version": "2008-10-17",
  "Statement": [
    {
      "Sid": "AllowCrossAccountPull",
      "Effect": "Allow",
      "Principal": {
        "AWS": [
          "arn:aws:iam::612713811844:root",
          "arn:aws:iam::720791945719:root",
          "arn:aws:iam::139282550922:root",
          "arn:aws:iam::184888967663:root",
          "arn:aws:iam::182498323465:root"
        ]
      },
      "Action": [
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:BatchCheckLayerAvailability",
        "ecr:InitiateLayerUpload",
        "ecr:PutImage",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload"
      ]
    }
  ]
}
EOF

echo "Generated ECR policy:"
cat /tmp/ecr-policy.json

echo "Attaching policy to ECR"
sudo aws ecr set-repository-policy \
  --repository-name "${REPO_NAME}" \
  --policy-text file:///tmp/ecr-policy.json \
  --region "${REGION}"

#--------THIS REPLICATION CONFIG ONLY WORKS IF THE ECR REPO IS CREATED IN THE OTHER ACCOUNTS FIRST-----#
sudo aws ecr put-replication-configuration --replication-configuration '{
  "rules": [{
    "destinations": [
      {"region": "us-east-1", "registryId": "612713811844"},
      {"region": "us-east-1", "registryId": "720791945719"},
      {"region": "us-east-1", "registryId": "139282550922"},
      {"region": "us-east-1", "registryId": "184888967663"}
    ]
  }]
}' || echo "Did not replicate to other accounts"


echo "ECR promotion pipeline completed successfully $(date)."

# optional: verify it’s running
ps aux | grep awsagent || true

###########################################################
# --- STEP 5: Push Image to Each Target Account ---
###########################################################
echo "Pushing image: $AUTO_ECR_IMAGE_URI"
# IFS=',' read -r -a TARGETS <<< "$TARGET_ACCOUNTS"

if [[ ! -f /tmp/k8selected_env.txt ]]
then
  echo "❌ Environment file not found. Exiting."
  exit 1
fi

ENVIRONMENT=$(cat /tmp/k8selected_env.txt | tr -d '[:space:]')
echo "🔧 Selected ENVIRONMENT: $ENVIRONMENT"

# Map to target AWS account ID
declare -A ENV_TO_ACCOUNT_MAP=(
  [dev]="612713811844"
  [test]="720791945719"
  [uat]="139282550922"
  [prod]="184888967663"
)

ACCOUNT_ID="${ENV_TO_ACCOUNT_MAP[$ENVIRONMENT]}"
echo "TARGET ACCOUNT DETECTED: ${ACCOUNT_ID}"

###########################################################
# --- STEP 5: Push Image to Target Account ---
###########################################################
IMAGE_TAG="${IMAGE_TAG:-activiti-img-1.0}" # fallback if not set

echo "==============================================="
echo " Processing Target Account: ${ACCOUNT_ID}"
echo "==============================================="

TARGET_ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
TARGET_ECR_IMAGE_URI="${TARGET_ECR_REGISTRY}/${REPO_NAME}:${IMAGE_TAG}"

echo "🔹 Logging into target ECR..."
aws ecr get-login-password --region "${REGION}" \
| sudo docker login --username AWS --password-stdin "${TARGET_ECR_REGISTRY}"

echo "🔹 Checking existing repo in ${ACCOUNT_ID}..."
if aws ecr describe-repositories --repository-names "${REPO_NAME}" --region "${REGION}" >/dev/null 2>&1; then
  echo "Repo exists in ${ACCOUNT_ID}...."
  # Optionally delete it:
  # aws ecr delete-repository --repository-name "${REPO_NAME}" --region "${REGION}" --force || true
else
  echo "No existing repo found in ${ACCOUNT_ID}."
fi


echo "🔹 Tagging and pushing to ${ACCOUNT_ID}..."
echo "Source: ${AUTO_ECR_IMAGE_URI}"
echo "Target: ${TARGET_ECR_IMAGE_URI}"

sudo docker tag "${AUTO_ECR_IMAGE_URI}" "${TARGET_ECR_IMAGE_URI}"
sudo docker push "${TARGET_ECR_IMAGE_URI}"

echo "Image pushed successfully to ${TARGET_ECR_IMAGE_URI}"

###########################################################
# --- STEP 6: Cleanup ---
###########################################################
sudo docker image prune -f
echo "🧹 Cleanup complete."
echo "🎉 ECR promotion completed successfully at $(date)"
