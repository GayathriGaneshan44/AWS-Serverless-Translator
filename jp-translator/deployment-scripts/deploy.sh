#!/usr/bin/env bash
# =============================================================================
#  deploy.sh  —  Full AWS CLI deployment for JP ↔ EN Translator
#
#  Prerequisites:
#    • AWS CLI v2 installed  (aws --version)
#    • AWS credentials configured  (aws configure)
#    • Python 3.11 available locally
#    • zip utility available
#
#  Usage:
#    chmod +x deploy.sh
#    ./deploy.sh
#
#  To tear everything down afterwards:
#    ./deploy.sh --destroy
# =============================================================================

set -euo pipefail

# ─── CONFIG — edit these values ───────────────────────────────────────────────
AWS_REGION="ap-south-1"           # Mumbai — closest to India; change if needed
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
LAMBDA_FUNCTION_NAME="jp-translator-fn"
LAMBDA_ROLE_NAME="jp-translator-lambda-role"
LAMBDA_POLICY_NAME="jp-translator-lambda-policy"
HISTORY_BUCKET="jp-translator-history-${AWS_ACCOUNT_ID}"
AUDIO_BUCKET="jp-translator-audio-${AWS_ACCOUNT_ID}"
FRONTEND_BUCKET="jp-translator-frontend-${AWS_ACCOUNT_ID}"
API_NAME="jp-translator-api"
STAGE_NAME="prod"
RESOURCE_PATH="translate"

echo ""
echo "============================================================"
echo "  JP Translator — AWS Deployment"
echo "  Region  : $AWS_REGION"
echo "  Account : $AWS_ACCOUNT_ID"
echo "============================================================"
echo ""

# ─── DESTROY MODE ─────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--destroy" ]]; then
  echo ">>> Destroying all resources..."

  API_ID=$(aws apigateway get-rest-apis \
    --query "items[?name=='$API_NAME'].id" \
    --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  [[ -n "$API_ID" ]] && aws apigateway delete-rest-api --rest-api-id "$API_ID" --region "$AWS_REGION" && echo "Deleted API Gateway"

  aws lambda delete-function --function-name "$LAMBDA_FUNCTION_NAME" --region "$AWS_REGION" 2>/dev/null && echo "Deleted Lambda" || true

  POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${LAMBDA_POLICY_NAME}"
  aws iam detach-role-policy --role-name "$LAMBDA_ROLE_NAME" --policy-arn "$POLICY_ARN" 2>/dev/null || true
  aws iam delete-policy --policy-arn "$POLICY_ARN" 2>/dev/null && echo "Deleted IAM policy" || true
  aws iam delete-role --role-name "$LAMBDA_ROLE_NAME" 2>/dev/null && echo "Deleted IAM role" || true

  for BUCKET in "$HISTORY_BUCKET" "$AUDIO_BUCKET" "$FRONTEND_BUCKET"; do
    aws s3 rm "s3://$BUCKET" --recursive 2>/dev/null || true
    aws s3 rb "s3://$BUCKET" --force 2>/dev/null && echo "Deleted bucket: $BUCKET" || true
  done

  echo ">>> Destroy complete."
  exit 0
fi

# ═══════════════════════════════════════════════════════════════
#  STEP 1 — Create S3 buckets
# ═══════════════════════════════════════════════════════════════
echo ">>> [1/9] Creating S3 buckets..."

for BUCKET in "$HISTORY_BUCKET" "$AUDIO_BUCKET" "$FRONTEND_BUCKET"; do
  if aws s3api head-bucket --bucket "$BUCKET" --region "$AWS_REGION" 2>/dev/null; then
    echo "  Bucket already exists: $BUCKET"
  else
    if [[ "$AWS_REGION" == "us-east-1" ]]; then
      aws s3api create-bucket --bucket "$BUCKET" --region "$AWS_REGION"
    else
      aws s3api create-bucket --bucket "$BUCKET" --region "$AWS_REGION" \
        --create-bucket-configuration LocationConstraint="$AWS_REGION"
    fi
    echo "  Created: $BUCKET"
  fi

  # Block all public access for data buckets
  aws s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,\
BlockPublicPolicy=true,RestrictPublicBuckets=true \
    --region "$AWS_REGION"
done

# CORS on audio bucket — browser needs to fetch the presigned URL
aws s3api put-bucket-cors --bucket "$AUDIO_BUCKET" --region "$AWS_REGION" \
  --cors-configuration '{
    "CORSRules": [{
      "AllowedHeaders": ["*"],
      "AllowedMethods": ["GET"],
      "AllowedOrigins": ["*"],
      "MaxAgeSeconds": 3600
    }]
  }'

echo "  S3 buckets ready."


# ═══════════════════════════════════════════════════════════════
#  STEP 2 — IAM role + policy
# ═══════════════════════════════════════════════════════════════
echo ""
echo ">>> [2/9] Creating IAM role and policy..."

TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "lambda.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}'

# Create role (skip if exists)
ROLE_ARN=$(aws iam get-role --role-name "$LAMBDA_ROLE_NAME" \
  --query Role.Arn --output text 2>/dev/null || \
  aws iam create-role \
    --role-name "$LAMBDA_ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --query Role.Arn --output text)

echo "  Role ARN: $ROLE_ARN"

# Create inline policy document (bucket names are account-specific)
POLICY_DOC=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Translate",
      "Effect": "Allow",
      "Action": ["translate:TranslateText"],
      "Resource": "*"
    },
    {
      "Sid": "Polly",
      "Effect": "Allow",
      "Action": ["polly:SynthesizeSpeech"],
      "Resource": "*"
    },
    {
      "Sid": "S3Audio",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject"],
      "Resource": "arn:aws:s3:::${AUDIO_BUCKET}/*"
    },
    {
      "Sid": "S3History",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject"],
      "Resource": "arn:aws:s3:::${HISTORY_BUCKET}/*"
    },
    {
      "Sid": "CloudWatch",
      "Effect": "Allow",
      "Action": ["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],
      "Resource": "arn:aws:logs:*:*:*"
    }
  ]
}
EOF
)

POLICY_ARN=$(aws iam get-policy \
  --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${LAMBDA_POLICY_NAME}" \
  --query Policy.Arn --output text 2>/dev/null || \
  aws iam create-policy \
    --policy-name "$LAMBDA_POLICY_NAME" \
    --policy-document "$POLICY_DOC" \
    --query Policy.Arn --output text)

echo "  Policy ARN: $POLICY_ARN"

aws iam attach-role-policy \
  --role-name "$LAMBDA_ROLE_NAME" \
  --policy-arn "$POLICY_ARN" 2>/dev/null || true

echo "  Waiting 10s for IAM propagation..."
sleep 10


# ═══════════════════════════════════════════════════════════════
#  STEP 3 — Package Lambda
# ═══════════════════════════════════════════════════════════════
echo ""
echo ">>> [3/9] Packaging Lambda function..."

LAMBDA_DIR="$(cd "$(dirname "$0")/../lambda" && pwd)"
DEPLOY_PKG="./jp-translator-lambda.zip"

rm -f "$DEPLOY_PKG"
cd "$LAMBDA_DIR"
powershell -Command "Compress-Archive -Path lambda_function.py -DestinationPath $DEPLOY_PKG"
echo "  Package: $DEPLOY_PKG"


# ═══════════════════════════════════════════════════════════════
#  STEP 4 — Create / update Lambda function
# ═══════════════════════════════════════════════════════════════
echo ""
echo ">>> [4/9] Deploying Lambda function..."

ENV_VARS="Variables={HISTORY_BUCKET=${HISTORY_BUCKET},AUDIO_BUCKET=${AUDIO_BUCKET},AUDIO_URL_TTL=3600}"

if aws lambda get-function --function-name "$LAMBDA_FUNCTION_NAME" \
    --region "$AWS_REGION" &>/dev/null; then
  echo "  Function exists — updating code..."
  aws lambda update-function-code \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --zip-file "fileb://$DEPLOY_PKG" \
    --region "$AWS_REGION" > /dev/null
  aws lambda update-function-configuration \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --environment "$ENV_VARS" \
    --region "$AWS_REGION" > /dev/null
else
  echo "  Creating new function..."
  aws lambda create-function \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --runtime python3.11 \
    --role "$ROLE_ARN" \
    --handler lambda_function.lambda_handler \
    --zip-file "fileb://$DEPLOY_PKG" \
    --timeout 30 \
    --memory-size 256 \
    --environment "$ENV_VARS" \
    --region "$AWS_REGION" > /dev/null
fi

LAMBDA_ARN=$(aws lambda get-function \
  --function-name "$LAMBDA_FUNCTION_NAME" \
  --region "$AWS_REGION" \
  --query Configuration.FunctionArn --output text)

echo "  Lambda ARN: $LAMBDA_ARN"


# ═══════════════════════════════════════════════════════════════
#  STEP 5 — API Gateway
# ═══════════════════════════════════════════════════════════════
echo ""
echo ">>> [5/9] Setting up API Gateway..."

# Check if API already exists
API_ID=$(aws apigateway get-rest-apis \
  --query "items[?name=='$API_NAME'].id" \
  --output text --region "$AWS_REGION")

if [[ -z "$API_ID" || "$API_ID" == "None" ]]; then
  API_ID=$(aws apigateway create-rest-api \
    --name "$API_NAME" \
    --description "JP-EN Translator API" \
    --region "$AWS_REGION" \
    --query id --output text)
  echo "  Created API: $API_ID"
else
  echo "  Existing API: $API_ID"
fi

# Get root resource
ROOT_ID=$(aws apigateway get-resources \
  --rest-api-id "$API_ID" \
  --region "$AWS_REGION" \
  --query "items[?path=='/'].id" --output text)

# Create /translate resource
RESOURCE_ID=$(aws apigateway get-resources \
  --rest-api-id "$API_ID" --region "$AWS_REGION" \
  --query "items[?pathPart=='$RESOURCE_PATH'].id" --output text)

if [[ -z "$RESOURCE_ID" || "$RESOURCE_ID" == "None" ]]; then
  RESOURCE_ID=$(aws apigateway create-resource \
    --rest-api-id "$API_ID" \
    --parent-id "$ROOT_ID" \
    --path-part "$RESOURCE_PATH" \
    --region "$AWS_REGION" \
    --query id --output text)
  echo "  Created resource: /$RESOURCE_PATH (id=$RESOURCE_ID)"
fi

# Create POST method
aws apigateway put-method \
  --rest-api-id "$API_ID" \
  --resource-id "$RESOURCE_ID" \
  --http-method POST \
  --authorization-type NONE \
  --region "$AWS_REGION" 2>/dev/null || true

# Create OPTIONS method for CORS preflight
aws apigateway put-method \
  --rest-api-id "$API_ID" \
  --resource-id "$RESOURCE_ID" \
  --http-method OPTIONS \
  --authorization-type NONE \
  --region "$AWS_REGION" 2>/dev/null || true

# Lambda proxy integration for POST
LAMBDA_URI="arn:aws:apigateway:${AWS_REGION}:lambda:path/2015-03-31/functions/${LAMBDA_ARN}/invocations"

aws apigateway put-integration \
  --rest-api-id "$API_ID" \
  --resource-id "$RESOURCE_ID" \
  --http-method POST \
  --type AWS_PROXY \
  --integration-http-method POST \
  --uri "$LAMBDA_URI" \
  --region "$AWS_REGION" > /dev/null

# Lambda proxy integration for OPTIONS (also handled by Lambda's CORS response)
aws apigateway put-integration \
  --rest-api-id "$API_ID" \
  --resource-id "$RESOURCE_ID" \
  --http-method OPTIONS \
  --type AWS_PROXY \
  --integration-http-method POST \
  --uri "$LAMBDA_URI" \
  --region "$AWS_REGION" > /dev/null

echo "  Integrations set."

# Grant API Gateway permission to invoke Lambda
aws lambda add-permission \
  --function-name "$LAMBDA_FUNCTION_NAME" \
  --statement-id "apigateway-invoke-${API_ID}" \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${AWS_REGION}:${AWS_ACCOUNT_ID}:${API_ID}/*/*/${RESOURCE_PATH}" \
  --region "$AWS_REGION" 2>/dev/null || true

echo "  Lambda permission granted."


# ═══════════════════════════════════════════════════════════════
#  STEP 6 — Deploy API to prod stage
# ═══════════════════════════════════════════════════════════════
echo ""
echo ">>> [6/9] Deploying API to stage '$STAGE_NAME'..."

DEPLOYMENT_ID=$(aws apigateway create-deployment \
  --rest-api-id "$API_ID" \
  --stage-name "$STAGE_NAME" \
  --description "Deployed by deploy.sh" \
  --region "$AWS_REGION" \
  --query id --output text)

echo "  Deployment ID: $DEPLOYMENT_ID"

API_INVOKE_URL="https://${API_ID}.execute-api.${AWS_REGION}.amazonaws.com/${STAGE_NAME}/${RESOURCE_PATH}"
echo "  API URL: $API_INVOKE_URL"


# ═══════════════════════════════════════════════════════════════
#  STEP 7 — Patch frontend with real API URL
# ═══════════════════════════════════════════════════════════════
echo ""
echo ">>> [7/9] Patching frontend with API URL..."

FRONTEND_DIR="$(cd "$(dirname "$0")/../frontend" && pwd)"
PATCHED_HTML="/tmp/index-patched.html"

sed "s|https://YOUR_API_ID.execute-api.YOUR_REGION.amazonaws.com/prod/translate|${API_INVOKE_URL}|g" \
  "$FRONTEND_DIR/index.html" > "$PATCHED_HTML"

echo "  Patched: $PATCHED_HTML"


# ═══════════════════════════════════════════════════════════════
#  STEP 8 — Upload frontend to S3
# ═══════════════════════════════════════════════════════════════
echo ""
echo ">>> [8/9] Uploading frontend to S3..."

aws s3 cp "$PATCHED_HTML" "s3://$FRONTEND_BUCKET/index.html" \
  --content-type "text/html" \
  --region "$AWS_REGION"

# Enable static website hosting
aws s3api put-bucket-website \
  --bucket "$FRONTEND_BUCKET" \
  --website-configuration '{"IndexDocument":{"Suffix":"index.html"},"ErrorDocument":{"Key":"index.html"}}' \
  --region "$AWS_REGION"

# Make frontend bucket publicly readable
aws s3api put-public-access-block \
  --bucket "$FRONTEND_BUCKET" \
  --public-access-block-configuration \
    BlockPublicAcls=false,IgnorePublicAcls=false,\
BlockPublicPolicy=false,RestrictPublicBuckets=false \
  --region "$AWS_REGION"

aws s3api put-bucket-policy \
  --bucket "$FRONTEND_BUCKET" \
  --policy "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[{
      \"Sid\":\"PublicRead\",
      \"Effect\":\"Allow\",
      \"Principal\":\"*\",
      \"Action\":\"s3:GetObject\",
      \"Resource\":\"arn:aws:s3:::${FRONTEND_BUCKET}/*\"
    }]
  }" \
  --region "$AWS_REGION"

FRONTEND_URL="http://${FRONTEND_BUCKET}.s3-website.${AWS_REGION}.amazonaws.com"
echo "  Frontend URL: $FRONTEND_URL"


# ═══════════════════════════════════════════════════════════════
#  STEP 9 — Print summary
# ═══════════════════════════════════════════════════════════════
echo ""
echo "============================================================"
echo "  Deployment complete!"
echo "============================================================"
echo ""
echo "  Frontend URL  :  $FRONTEND_URL"
echo "  API URL       :  $API_INVOKE_URL"
echo "  Lambda        :  $LAMBDA_FUNCTION_NAME"
echo "  History S3    :  s3://$HISTORY_BUCKET"
echo "  Audio S3      :  s3://$AUDIO_BUCKET"
echo ""
echo "  To test the API directly:"
echo "    curl -X POST '$API_INVOKE_URL' \\"
echo "      -H 'Content-Type: application/json' \\"
echo "      -d '{\"text\":\"会議を始めます\",\"direction\":\"ja-en\"}'"
echo ""
echo "  To destroy all resources:"
echo "    ./deploy.sh --destroy"
echo "============================================================"
