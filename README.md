# Floci

Floci is a fast, free, and open-source local AWS service emulator. It solves the challenges of high cloud costs, slow development cycles, and privacy concerns by providing a local environment that mimics AWS services with zero telemetry and full compatibility with standard AWS SDKs and CLI tools.

## TLDR

```bash
mkdir data
docker run --name floci-aws -d \
       -v ./data:/app/data \
       -v /var/run/docker.sock:/var/run/docker.sock \
       -p 4566:4566 \
       floci/floci:latest
aws --endpoint-url http://localhost:4566 s3 mb s3://file-storage
aws --endpoint-url http://localhost:4566 s3 ls
aws --endpoint-url http://localhost:4566 s3 rm s3://file-storage
aws --endpoint-url http://localhost:4566 s3 ls
docker rm --force floci-aws
```

The volume to map `/var/run/docker.sock` gives Floci the ability to run new containers, needed by EC2 service (and others). Remove it if you think this is a potential security problem in your environment.

---

The following sections provide detailed guides for common AWS services. To use these commands, ensure you have **Docker** and the **AWS CLI** installed. Configure your CLI with dummy credentials (optional):

```bash
aws configure set aws_access_key_id test
aws configure set aws_secret_access_key test
aws configure set region us-east-1
```

If you want the support of other operating systems for EC2 instances use:

```bash
docker run --name floci-aws -d \
       -e AMI_IMAGE_MAPPING=ami-01:public.ecr.aws/amazonlinux/amazonlinux:2,ami-02:public.ecr.aws/ubuntu/ubuntu:22.04,ami-03:public.ecr.aws/docker/library/debian:12 \
       -v /var/run/docker.sock:/var/run/docker.sock \
       -v ./data:/app/data \
       -p 4566:4566 \
       floci/floci:latest
```

You will also need these commands:
- ssh-keygen
- ssh
- zip

And some recommended commands (or their equivalents):
- sudo
- nc
- ss

Tests were made in a Windows computer with 24GB of RAM and NVIDIA GTX 1650 with 4GB of VRAM. All commands were installed in a Debian WSL environment.

## AWS S3

Objective: Create a bucket, upload a file, and query it using S3 Select.

- Step 1: Create a bucket.
```bash
aws --endpoint-url http://localhost:4566 s3 mb s3://file-storage
```
- Step 2: Upload a local file to the bucket.
```bash
echo "hello floci" > hello.txt
aws --endpoint-url http://localhost:4566 s3 cp hello.txt s3://file-storage/hello.txt
```
- Step 3: List the bucket contents.
```bash
aws --endpoint-url http://localhost:4566 s3 ls s3://file-storage
```
- Step 4: Remove file from bucket.
```bash
aws --endpoint-url http://localhost:4566 s3 rm s3://file-storage/hello.txt
aws --endpoint-url http://localhost:4566 s3 ls s3://file-storage
```
- Step 5: Remove bucket.
```bash
aws --endpoint-url http://localhost:4566 s3 rm s3://file-storage
aws --endpoint-url http://localhost:4566 s3 ls
```

Result: A fully functional local S3 environment with support for object storage and S3 Select. The total time to run all commands at once was 2.790 seconds. 

References:
- [https://floci.io/floci/services/s3/](https://floci.io/floci/services/s3/)

## AWS EC2

Objective: Launch and manage virtual machine instances (Docker containers) locally with SSH access.

- Step 1: Generate an SSH key pair in the current directory (using Ed25519).
    - `-N ""`: no passphrase.
```bash
ssh-keygen -t ed25519 -f ./id_ed25519 -N ""
```
- Step 2: Import the public key into Floci.
```bash
aws --endpoint-url http://localhost:4566 ec2 import-key-pair --key-name my-key --public-key-material fileb://id_ed25519.pub
```
- Step 3: Launch an instance. 
    - **Note**: The instance will stay in `pending` for a few moments while Floci pulls the required Docker image.
    - AMI `ami-000000000001` is the only one allowed and means `Amazon Linux 2023`.
    - Use `ami-01`, `ami-02`, and `ami-03` if you are using the version with multiple AMIs support.
```bash
AWS_EC2_ID=$(aws --endpoint-url http://localhost:4566 ec2 run-instances --image-id ami-000000000001 --instance-type t2.micro --key-name my-key --query 'Instances[0].InstanceId' --output text)
echo "Instance ID: $AWS_EC2_ID"
aws --endpoint-url http://localhost:4566 ec2 describe-instances --instance-ids $AWS_EC2_ID
```
- Step 4: Wait for the instance to reach the `running` state.
```bash
aws --endpoint-url http://localhost:4566 ec2 wait instance-running --instance-ids $AWS_EC2_ID
```
- Step 5: Check if Docker backend is working.
```bash
docker ps -a |grep -E "(NAMES|$AWS_EC2_ID)"
docker exec -it floci-ec2-$AWS_EC2_ID cat /etc/os-release
```
- Step 6: Connect via SSH using the `root` user (port 2200).
    - It uses the sequence of ports from 2200 to 2299 for each new instance.
```bash
sudo ss -ntlp
ssh -i id_ed25519 -p 2200 root@localhost
```
- Step 7: Terminate the instance when finished.
```bash
aws --endpoint-url http://localhost:4566 ec2 terminate-instances --instance-ids $AWS_EC2_ID
```

Result: Local EC2 instances running as Docker containers with full SSH access and IMDS support.

References:
- [https://floci.io/floci/services/ec2/](https://floci.io/floci/services/ec2/)

## AWS EC2 + S3

Objective: Demonstrate seamless integration by uploading data to S3 and retrieving it directly from within a running EC2 instance.

- Step 1: Create an S3 bucket and upload a "workload" file from your host.
```bash
aws --endpoint-url http://localhost:4566 s3 mb s3://integration-bucket
echo "This data was fetched from S3 inside EC2" > workload.txt
aws --endpoint-url http://localhost:4566 s3 cp workload.txt s3://integration-bucket/workload.txt
```

- Step 2: Launch an EC2 instance.
    - Ensure you have imported your SSH key as shown in the **AWS EC2** section.
```bash
AWS_EC2_ID=$(aws --endpoint-url http://localhost:4566 ec2 run-instances --image-id ami-000000000001 --instance-type t2.micro --key-name my-key --query 'Instances[0].InstanceId' --output text)
aws --endpoint-url http://localhost:4566 ec2 wait instance-running --instance-ids $AWS_EC2_ID
```

- Step 3: Access the S3 bucket from *inside* the EC2 instance.
    - We use `docker exec` to run the AWS CLI inside the instance container.
    - **Note**: Inside the container, we use the host's IP or the Floci container name (`floci-aws`) to reach the service.
```bash
# Get Floci container IP to ensure reachability from the EC2 container
FLOCI_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' floci-aws)

# Download the file from S3 using the AWS CLI inside the EC2 instance
docker exec -it floci-ec2-$AWS_EC2_ID dnf install -y aws-cli
docker exec -it floci-ec2-$AWS_EC2_ID bash -c '
        aws configure set aws_access_key_id test;
        aws configure set aws_secret_access_key test;
        aws configure set region us-east-1;
'
docker exec -it floci-ec2-$AWS_EC2_ID aws --endpoint-url http://$FLOCI_IP:4566 s3 cp s3://integration-bucket/workload.txt /tmp/workload.txt
docker exec -it floci-ec2-$AWS_EC2_ID cat /tmp/workload.txt
```

- Step 4: Clean up resources.
```bash
aws --endpoint-url http://localhost:4566 ec2 terminate-instances --instance-ids $AWS_EC2_ID
aws --endpoint-url http://localhost:4566 s3 rb s3://integration-bucket --force
```

Result: Verified end-to-end integration between compute (EC2) and storage (S3) services running locally. The EC2 instance successfully retrieved and processed data stored in S3, simulating a real-world cloud architecture.

References:
- [https://floci.io/floci/services/ec2/](https://floci.io/floci/services/ec2/)
- [https://floci.io/floci/services/s3/](https://floci.io/floci/services/s3/)

## S3 + Lambda + SQS + DynamoDB + API Gateway flow

This section demonstrates a complete serverless event-driven architecture running locally. It simulates a data ingestion pipeline where a CSV file uploaded to S3 triggers a chain of events, ultimately storing the data in DynamoDB and making it accessible via an API. For a deep dive into the implementation details, please consult the `scripts/01-run-lambda-flow.sh` script.

```text
peolpe.csv ──► S3 Bucket ──► trigger ──► Lambda ──► SQS ──► trigger  ──► Lambda ──► DynamoDB
```

```text
API Gateway ───► Lambda ───► DynamoDB
    JSON ◄─────────┘
```

Requisites:
- Change `WSL_IP` inside `./scripts/run-lambda-flow` to the IP where you are runing your Docker service. I am running inside WSL.

Execution:
```bash
bash scripts/01-run-lambda-flow.sh
```

The script automates the entire setup: creating the Floci container, provisioning S3 buckets, SQS queues, DynamoDB tables, and deploying Python-based Lambda functions with their respective triggers. Upon completion, you will see logs confirming the successful ingestion of `people.csv` data into DynamoDB and a final verification step that queries the data through the API Gateway endpoint. To tear down the environment, you can stop and remove the Floci Docker container (`docker rm --force floci-aws`). 

The script uses `WSL_IP` (defaulting to `172.22.185.230`) to facilitate communication between the host and the services running inside the Docker network. When running in your own environment, ensure `WSL_IP` matches your host's IP address on the network shared with Docker, or `localhost` if your setup supports it.

Some useful commands to check the AWS/Floci resources by using `aws` command:

```bash
WSL_IP="172.22.185.230"
# === List S3 Buckets and Files ===
aws --endpoint-url http://$WSL_IP:4566 s3 ls
aws --endpoint-url http://$WSL_IP:4566 s3 ls s3://people-s3-bucket
# === List Lambda Functions ===
aws --endpoint-url http://$WSL_IP:4566 lambda list-functions|grep '"FunctionName":'|tr -s ' ' ' '
# === List Lambda Event Mappins (Source=SQS / Triggers=Lambda people-sqs-queue)===
aws --endpoint-url http://$WSL_IP:4566 lambda  list-event-source-mappings
# === List API Gateways ===
aws --endpoint-url http://$WSL_IP:4566 apigateway get-rest-apis
# === List SQS Gateways ===
aws --endpoint-url http://$WSL_IP:4566 sqs list-queues
# === List DynamoDB Tables ===
aws --endpoint-url http://$WSL_IP:4566 dynamodb list-tables
```
