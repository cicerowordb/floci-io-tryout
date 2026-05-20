#!/usr/bin/env bash
set -euo pipefail

# Variables
WSL_IP="${WSL_IP:-172.22.185.230}"
CONTAINER_NAME="${CONTAINER_NAME:-floci-aws}"
NETWORK_NAME="${NETWORK_NAME:-floci-net}"
IMAGE="${IMAGE:-floci/floci:latest}"

HOST_ENDPOINT_URL="${HOST_ENDPOINT_URL:-http://${WSL_IP}:4566}"
LAMBDA_ENDPOINT_URL="${LAMBDA_ENDPOINT_URL:-http://${CONTAINER_NAME}:4566}"

AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-000000000000}"

BUCKET="${BUCKET:-people-s3-bucket}"
CSV_KEY="${CSV_KEY:-people.csv}"
QUEUE_NAME="${QUEUE_NAME:-people-sqs-queue}"
TABLE="${TABLE:-people-dynamodb}"
S3_TO_SQS_FUNCTION_NAME="${S3_TO_SQS_FUNCTION_NAME:-people-s3-to-sqs}"
SQS_TO_DDB_FUNCTION_NAME="${SQS_TO_DDB_FUNCTION_NAME:-people-sqs-to-dynamodb}"
LIST_FUNCTION_NAME="${LIST_FUNCTION_NAME:-people-list}"
API_NAME="${API_NAME:-people-api}"
API_STAGE="${API_STAGE:-dev}"

HOST_QUEUE_URL="${HOST_ENDPOINT_URL}/${AWS_ACCOUNT_ID}/${QUEUE_NAME}"
LAMBDA_QUEUE_URL="${LAMBDA_ENDPOINT_URL}/${AWS_ACCOUNT_ID}/${QUEUE_NAME}"

#ROOT_DIR="$(pwd)"
WORK_DIR="${WORK_DIR:-/tmp/run-lambda-flow-dir}"
DATA_DIR="${DATA_DIR:-/tmp/run-lambda-flow-data}"

export AWS_DEFAULT_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

log() {
   printf '\n==> %s\n' "$*"
}

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

aws_cli() {
  AWS_ENDPOINT_URL="$HOST_ENDPOINT_URL" aws --endpoint-url "$HOST_ENDPOINT_URL" "$@"
}

wait_for_floci() {
  local attempt

  for attempt in $(seq 1 10); do
    if aws_cli s3 ls >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  printf 'Floci did not become ready at %s\n' "$HOST_ENDPOINT_URL" >&2
  docker logs "$CONTAINER_NAME" >&2 || true
  exit 1
}

delete_event_source_mappings() {
  local function_name
  local uuid
  local mappings_file="${WORK_DIR}/event-source-mappings.json"

  for function_name in "$S3_TO_SQS_FUNCTION_NAME" "$SQS_TO_DDB_FUNCTION_NAME"; do
    if ! aws_cli lambda list-event-source-mappings \
      --function-name "$function_name" > "$mappings_file" 2>/dev/null; then
      continue
    fi

    while IFS= read -r uuid; do
      [ -n "$uuid" ] || continue
      aws_cli lambda delete-event-source-mapping --uuid "$uuid" >/dev/null 2>&1 || true
    done < <(
      python3 - "$mappings_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)

for mapping in data.get("EventSourceMappings", []):
    uuid = mapping.get("UUID")
    if uuid:
        print(uuid)
PY
    )
  done
}

delete_people_rest_apis() {
  local api_id
  local apis_file="${WORK_DIR}/rest-apis.json"

  if ! aws_cli apigateway get-rest-apis > "$apis_file" 2>/dev/null; then
    return 0
  fi

  while IFS= read -r api_id; do
    [ -n "$api_id" ] || continue
    aws_cli apigateway delete-rest-api --rest-api-id "$api_id" >/dev/null 2>&1 || true
  done < <(
    python3 - "$apis_file" "$API_NAME" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)

for api in data.get("items", []):
    if api.get("name") == sys.argv[2]:
        print(api["id"])
PY
  )
}

reset_local_resources() {
  mkdir -p "$WORK_DIR"
  delete_event_source_mappings
  delete_people_rest_apis

  aws_cli lambda delete-function \
    --function-name "$S3_TO_SQS_FUNCTION_NAME" >/dev/null 2>&1 || true
  aws_cli lambda delete-function \
    --function-name "$SQS_TO_DDB_FUNCTION_NAME" >/dev/null 2>&1 || true
  aws_cli lambda delete-function \
    --function-name "$LIST_FUNCTION_NAME" >/dev/null 2>&1 || true

  aws_cli sqs delete-queue --queue-url "$HOST_QUEUE_URL" >/dev/null 2>&1 || true

  if aws_cli dynamodb describe-table --table-name "$TABLE" >/dev/null 2>&1; then
    aws_cli dynamodb delete-table --table-name "$TABLE" >/dev/null
    aws_cli dynamodb wait table-not-exists --table-name "$TABLE" >/dev/null
  fi

  aws_cli s3 rb "s3://${BUCKET}" --force >/dev/null 2>&1 || true
}

write_demo_files() {
  rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR"

  cat > "${WORK_DIR}/people.csv" <<'CSV'
id,name,email
1,Ada Lovelace,ada@example.test
2,Grace Hopper,grace@example.test
3,Katherine Johnson,katherine@example.test
CSV

  cat > "${WORK_DIR}/s3_to_sqs_lambda.py" <<'PY'
import csv
import io
import json
import os
import urllib.parse

import boto3


def client(service_name):
    return boto3.client(
        service_name,
        endpoint_url=os.environ["AWS_ENDPOINT_URL"],
        region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"),
        aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID", "test"),
        aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY", "test"),
    )


def handler(event, context):
    default_bucket = os.environ["PEOPLE_BUCKET"]
    default_key = os.environ["PEOPLE_KEY"]
    queue_url = os.environ["PEOPLE_QUEUE_URL"]

    records = event.get("Records") or [
        {"s3": {"bucket": {"name": default_bucket}, "object": {"key": default_key}}}
    ]

    s3 = client("s3")
    sqs = client("sqs")
    sent_ids = []

    for record in records:
        s3_record = record.get("s3", {})
        bucket = s3_record.get("bucket", {}).get("name", default_bucket)
        key = urllib.parse.unquote_plus(
            s3_record.get("object", {}).get("key", default_key)
        )

        if bucket != default_bucket or key != default_key:
            continue

        obj = s3.get_object(Bucket=bucket, Key=key)
        body = obj["Body"].read().decode("utf-8")

        for row in csv.DictReader(io.StringIO(body)):
            sqs.send_message(QueueUrl=queue_url, MessageBody=json.dumps(row))
            sent_ids.append(row["id"])

    return {"sent_count": len(sent_ids), "sent_ids": sent_ids}
PY

  cat > "${WORK_DIR}/sqs_to_dynamodb_lambda.py" <<'PY'
import json
import os

import boto3


def client(service_name):
    return boto3.client(
        service_name,
        endpoint_url=os.environ["AWS_ENDPOINT_URL"],
        region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"),
        aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID", "test"),
        aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY", "test"),
    )


def handler(event, context):
    table = os.environ["PEOPLE_TABLE"]
    dynamodb = client("dynamodb")
    inserted_ids = []

    for record in event.get("Records", []):
        row = json.loads(record.get("body") or record.get("Body") or "{}")
        if not row:
            continue

        item = {field: {"S": str(value)} for field, value in row.items()}
        dynamodb.put_item(TableName=table, Item=item)
        inserted_ids.append(row["id"])

    return {"inserted_count": len(inserted_ids), "inserted_ids": inserted_ids}
PY

  cat > "${WORK_DIR}/people_list_lambda.py" <<'PY'
import json
import os

import boto3


def client(service_name):
    return boto3.client(
        service_name,
        endpoint_url=os.environ["AWS_ENDPOINT_URL"],
        region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"),
        aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID", "test"),
        aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY", "test"),
    )


def decode_item(raw_item):
    return {name: next(iter(value.values())) for name, value in raw_item.items()}


def handler(event, context):
    dynamodb = client("dynamodb")
    scan_kwargs = {"TableName": os.environ["PEOPLE_TABLE"]}
    items = []

    while True:
        page = dynamodb.scan(**scan_kwargs)
        items.extend(decode_item(item) for item in page.get("Items", []))

        last_key = page.get("LastEvaluatedKey")
        if not last_key:
            break

        scan_kwargs["ExclusiveStartKey"] = last_key

    items.sort(key=lambda item: item["id"])

    return {
        "statusCode": 200,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(items),
        "isBase64Encoded": False,
    }
PY

  cat > "${WORK_DIR}/s3-to-sqs-env.json" <<JSON
{
  "Variables": {
    "AWS_ENDPOINT_URL": "${LAMBDA_ENDPOINT_URL}",
    "AWS_DEFAULT_REGION": "${AWS_DEFAULT_REGION}",
    "AWS_ACCESS_KEY_ID": "${AWS_ACCESS_KEY_ID}",
    "AWS_SECRET_ACCESS_KEY": "${AWS_SECRET_ACCESS_KEY}",
    "PEOPLE_BUCKET": "${BUCKET}",
    "PEOPLE_KEY": "${CSV_KEY}",
    "PEOPLE_QUEUE_URL": "${LAMBDA_QUEUE_URL}"
  }
}
JSON

  cat > "${WORK_DIR}/sqs-to-dynamodb-env.json" <<JSON
{
  "Variables": {
    "AWS_ENDPOINT_URL": "${LAMBDA_ENDPOINT_URL}",
    "AWS_DEFAULT_REGION": "${AWS_DEFAULT_REGION}",
    "AWS_ACCESS_KEY_ID": "${AWS_ACCESS_KEY_ID}",
    "AWS_SECRET_ACCESS_KEY": "${AWS_SECRET_ACCESS_KEY}",
    "PEOPLE_TABLE": "${TABLE}"
  }
}
JSON

  cat > "${WORK_DIR}/people-list-env.json" <<JSON
{
  "Variables": {
    "AWS_ENDPOINT_URL": "${LAMBDA_ENDPOINT_URL}",
    "AWS_DEFAULT_REGION": "${AWS_DEFAULT_REGION}",
    "AWS_ACCESS_KEY_ID": "${AWS_ACCESS_KEY_ID}",
    "AWS_SECRET_ACCESS_KEY": "${AWS_SECRET_ACCESS_KEY}",
    "PEOPLE_TABLE": "${TABLE}"
  }
}
JSON

  (
    cd "$WORK_DIR"
    zip -q s3-to-sqs.zip s3_to_sqs_lambda.py
    zip -q sqs-to-dynamodb.zip sqs_to_dynamodb_lambda.py
    zip -q people-list.zip people_list_lambda.py
  )
}

start_floci() {
  mkdir -p "$DATA_DIR"

  if docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
    docker rm --force "$CONTAINER_NAME" >/dev/null
  fi

  if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    docker network create "$NETWORK_NAME" >/dev/null
  fi

  docker run --name "$CONTAINER_NAME" -d \
    --network "$NETWORK_NAME" \
    --network-alias "$CONTAINER_NAME" \
    -e "FLOCI_HOSTNAME=${CONTAINER_NAME}" \
    -e "FLOCI_SERVICES_DOCKER_NETWORK=${NETWORK_NAME}" \
    -e "FLOCI_SERVICES_LAMBDA_DOCKER_NETWORK=${NETWORK_NAME}" \
    -e "FLOCI_SERVICES_LAMBDA_EPHEMERAL=true" \
    -e "FLOCI_STORAGE_HOST_PERSISTENT_PATH=${DATA_DIR}" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${DATA_DIR}:/app/data" \
    -p 4566:4566 \
    "$IMAGE" >/dev/null
}

create_bucket() {
  aws_cli s3 mb "s3://${BUCKET}" >/dev/null
}

upload_csv() {
  aws_cli s3 cp "${WORK_DIR}/people.csv" "s3://${BUCKET}/${CSV_KEY}" >/dev/null
  aws_cli s3 ls "s3://${BUCKET}/"
}

create_queue() {
  aws_cli sqs create-queue --queue-name "$QUEUE_NAME" >/dev/null
  aws_cli sqs get-queue-attributes \
    --queue-url "$HOST_QUEUE_URL" \
    --attribute-names QueueArn > "${WORK_DIR}/queue-attributes.json"

  python3 - "${WORK_DIR}/queue-attributes.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    attrs = json.load(fh)["Attributes"]

print(attrs["QueueArn"])
PY
}

queue_arn() {
  python3 - "${WORK_DIR}/queue-attributes.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    attrs = json.load(fh)["Attributes"]

print(attrs["QueueArn"])
PY
}

create_table() {
  aws_cli dynamodb create-table \
    --table-name "$TABLE" \
    --attribute-definitions AttributeName=id,AttributeType=S \
    --key-schema AttributeName=id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST >/dev/null

  aws_cli dynamodb wait table-exists --table-name "$TABLE" >/dev/null
}

create_lambdas() {
  aws_cli lambda create-function \
    --function-name "$S3_TO_SQS_FUNCTION_NAME" \
    --runtime python3.13 \
    --role arn:aws:iam::000000000000:role/lambda-role \
    --handler s3_to_sqs_lambda.handler \
    --timeout 60 \
    --memory-size 256 \
    --zip-file "fileb://${WORK_DIR}/s3-to-sqs.zip" \
    --environment "file://${WORK_DIR}/s3-to-sqs-env.json" >/dev/null

  aws_cli lambda create-function \
    --function-name "$SQS_TO_DDB_FUNCTION_NAME" \
    --runtime python3.13 \
    --role arn:aws:iam::000000000000:role/lambda-role \
    --handler sqs_to_dynamodb_lambda.handler \
    --timeout 60 \
    --memory-size 256 \
    --zip-file "fileb://${WORK_DIR}/sqs-to-dynamodb.zip" \
    --environment "file://${WORK_DIR}/sqs-to-dynamodb-env.json" >/dev/null

  aws_cli lambda create-function \
    --function-name "$LIST_FUNCTION_NAME" \
    --runtime python3.13 \
    --role arn:aws:iam::000000000000:role/lambda-role \
    --handler people_list_lambda.handler \
    --timeout 60 \
    --memory-size 256 \
    --zip-file "fileb://${WORK_DIR}/people-list.zip" \
    --environment "file://${WORK_DIR}/people-list-env.json" >/dev/null
}

connect_sqs_to_lambda() {
  aws_cli lambda create-event-source-mapping \
    --function-name "$SQS_TO_DDB_FUNCTION_NAME" \
    --event-source-arn "$(queue_arn)" \
    --batch-size 10 >/dev/null
}

connect_s3_to_lambda() {
  local function_arn

  aws_cli lambda add-permission \
    --function-name "$S3_TO_SQS_FUNCTION_NAME" \
    --statement-id allow-s3-object-created \
    --action lambda:InvokeFunction \
    --principal s3.amazonaws.com \
    --source-arn "arn:aws:s3:::${BUCKET}" >/dev/null

  function_arn="$(aws_cli lambda get-function \
    --function-name "$S3_TO_SQS_FUNCTION_NAME" \
    --query 'Configuration.FunctionArn' \
    --output text)"

  cat > "${WORK_DIR}/bucket-notification.json" <<JSON
{
  "LambdaFunctionConfigurations": [
    {
      "Id": "people-csv-to-sqs",
      "LambdaFunctionArn": "${function_arn}",
      "Events": ["s3:ObjectCreated:*"],
      "Filter": {
        "Key": {
          "FilterRules": [
            {"Name": "suffix", "Value": "${CSV_KEY}"}
          ]
        }
      }
    }
  ]
}
JSON

  aws_cli s3api put-bucket-notification-configuration \
    --bucket "$BUCKET" \
    --notification-configuration "file://${WORK_DIR}/bucket-notification.json"
}

create_api_gateway() {
  local api_id
  local deployment_id
  local function_arn
  local integration_uri
  local resource_id
  local root_id

  api_id="$(aws_cli apigateway create-rest-api \
    --name "$API_NAME" \
    --query id \
    --output text)"
  printf '%s\n' "$api_id" > "${WORK_DIR}/api-id.txt"

  root_id="$(aws_cli apigateway get-resources \
    --rest-api-id "$api_id" \
    --query 'items[?path==`/`].id' \
    --output text)"

  resource_id="$(aws_cli apigateway create-resource \
    --rest-api-id "$api_id" \
    --parent-id "$root_id" \
    --path-part people \
    --query id \
    --output text)"

  aws_cli apigateway put-method \
    --rest-api-id "$api_id" \
    --resource-id "$resource_id" \
    --http-method GET \
    --authorization-type NONE >/dev/null

  aws_cli lambda add-permission \
    --function-name "$LIST_FUNCTION_NAME" \
    --statement-id allow-apigateway-get-people \
    --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:${AWS_DEFAULT_REGION}:${AWS_ACCOUNT_ID}:${api_id}/*/GET/people" >/dev/null

  function_arn="$(aws_cli lambda get-function \
    --function-name "$LIST_FUNCTION_NAME" \
    --query 'Configuration.FunctionArn' \
    --output text)"

  integration_uri="arn:aws:apigateway:${AWS_DEFAULT_REGION}:lambda:path/2015-03-31/functions/${function_arn}/invocations"

  aws_cli apigateway put-integration \
    --rest-api-id "$api_id" \
    --resource-id "$resource_id" \
    --http-method GET \
    --type AWS_PROXY \
    --integration-http-method POST \
    --uri "$integration_uri" >/dev/null

  deployment_id="$(aws_cli apigateway create-deployment \
    --rest-api-id "$api_id" \
    --query id \
    --output text)"

  aws_cli apigateway create-stage \
    --rest-api-id "$api_id" \
    --stage-name "$API_STAGE" \
    --deployment-id "$deployment_id" >/dev/null

  printf '%s/restapis/%s/%s/_user_request_/people\n' \
    "$HOST_ENDPOINT_URL" "$api_id" "$API_STAGE"
}

table_matches_expected() {
  local mode="$1"

  python3 - "${WORK_DIR}/dynamodb-scan.json" "$mode" <<'PY'
import json
import sys

expected = {
    "1": {"id": "1", "name": "Ada Lovelace", "email": "ada@example.test"},
    "2": {"id": "2", "name": "Grace Hopper", "email": "grace@example.test"},
    "3": {"id": "3", "name": "Katherine Johnson", "email": "katherine@example.test"},
}

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)

actual = {}
for raw_item in data.get("Items", []):
    item = {name: next(iter(value.values())) for name, value in raw_item.items()}
    actual[item["id"]] = item

if actual == expected:
    if sys.argv[2] != "quiet":
        print(json.dumps([actual[key] for key in sorted(actual)], indent=2))
        print("Verified 3 DynamoDB rows from people.csv.")
    sys.exit(0)

if sys.argv[2] != "quiet":
    print("DynamoDB content mismatch.", file=sys.stderr)
    print("Expected:", json.dumps(expected, indent=2, sort_keys=True), file=sys.stderr)
    print("Actual:", json.dumps(actual, indent=2, sort_keys=True), file=sys.stderr)

sys.exit(1)
PY
}

wait_for_table_contents() {
  local attempt

  for attempt in $(seq 1 60); do
    aws_cli dynamodb scan --table-name "$TABLE" > "${WORK_DIR}/dynamodb-scan.json"

    if table_matches_expected quiet; then
      table_matches_expected verbose
      return 0
    fi

    sleep 1
  done

  table_matches_expected verbose || true
  docker logs "$CONTAINER_NAME" >&2 || true
  exit 1
}

verify_api_gateway_response() {
  local api_id
  local api_url

  api_id="$(cat "${WORK_DIR}/api-id.txt")"
  api_url="${HOST_ENDPOINT_URL}/restapis/${api_id}/${API_STAGE}/_user_request_/people"

  curl -fsS "$api_url" > "${WORK_DIR}/api-response.json"
  cat "${WORK_DIR}/api-response.json"
  printf '\n'

  python3 - "${WORK_DIR}/api-response.json" <<'PY'
import json
import sys

expected = [
    {"id": "1", "name": "Ada Lovelace", "email": "ada@example.test"},
    {"id": "2", "name": "Grace Hopper", "email": "grace@example.test"},
    {"id": "3", "name": "Katherine Johnson", "email": "katherine@example.test"},
]

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    actual = json.load(fh)

if actual != expected:
    print("API Gateway response mismatch.", file=sys.stderr)
    print("Expected:", json.dumps(expected, indent=2, sort_keys=True), file=sys.stderr)
    print("Actual:", json.dumps(actual, indent=2, sort_keys=True), file=sys.stderr)
    sys.exit(1)

print("Verified API Gateway GET /people response.")
PY
}

main() {
  need pwd
  need aws
  need curl
  need docker
  need python3
  need seq
  need zip

  log "Writing local CSV and Lambda packages"
  write_demo_files

  log "Starting Floci container ${CONTAINER_NAME}"
  start_floci

  log "Waiting for Floci at ${HOST_ENDPOINT_URL}"
  wait_for_floci

  log "Resetting local Floci resources"
  reset_local_resources

  log "Creating S3 bucket ${BUCKET}"
  create_bucket

  log "Creating SQS queue ${QUEUE_NAME}"
  create_queue

  log "Creating DynamoDB table ${TABLE}"
  create_table

  log "Creating Lambda functions ${S3_TO_SQS_FUNCTION_NAME}, ${SQS_TO_DDB_FUNCTION_NAME}, and ${LIST_FUNCTION_NAME}"
  create_lambdas

  log "Connecting SQS queue trigger to ${SQS_TO_DDB_FUNCTION_NAME}"
  connect_sqs_to_lambda

  log "Connecting S3 object-created trigger to ${S3_TO_SQS_FUNCTION_NAME}"
  connect_s3_to_lambda

  log "Creating API Gateway GET /people -> ${LIST_FUNCTION_NAME}"
  create_api_gateway

  log "Uploading people.csv to start: S3 -> Lambda -> SQS -> Lambda -> DynamoDB"
  upload_csv

  log "Reading DynamoDB table and checking content"
  wait_for_table_contents

  log "Calling API Gateway GET /people and checking response"
  verify_api_gateway_response

  log "Done. Floci is still running in Docker container ${CONTAINER_NAME}."
}

main "$@"
