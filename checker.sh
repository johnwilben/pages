#!/bin/bash
echo "=============================================="
echo "  Finals Exam Checker (Full)"
echo "=============================================="
echo ""
read -p "Enter your student ID: " SID
echo "Select your set:"
echo "  1) Set A (Inventory Tracker)"
echo "  2) Set B (Student Grades)"
read -p "Enter 1 or 2: " SET_NUM

if [ -z "$SID" ]; then echo "No ID entered."; exit 1; fi

BUCKET="finals-${SID}"
FUNC="ProcessCSV-${SID}"
REGION="ap-southeast-1"
SCORE=0

if [ "$SET_NUM" = "1" ]; then
  JSON_FILE="data/inventory.json"
  SET_NAME="A"
elif [ "$SET_NUM" = "2" ]; then
  JSON_FILE="data/grades.json"
  SET_NAME="B"
else
  echo "Invalid set."; exit 1
fi

echo ""
echo "Bucket: $BUCKET | Function: $FUNC | Set: $SET_NAME"
echo ""

# ── 1. S3 Website (15 pts) ──
echo "-- [15 pts] S3 Static Website --"
WEBSITE_URL="http://${BUCKET}.s3-website-${REGION}.amazonaws.com"
HTTP_CODE=$(curl -s -o /tmp/exam_page.html -w "%{http_code}" --max-time 10 "$WEBSITE_URL" 2>/dev/null)
if [ "$HTTP_CODE" = "200" ]; then
  echo "  [PASS] Website loads (${WEBSITE_URL})"
  SCORE=$((SCORE + 15))
else
  echo "  [FAIL] Website not accessible (HTTP $HTTP_CODE)"
fi

# ── 1b. Student Name on Website (10 pts) ──
echo ""
echo "-- [10 pts] Student Name on Dashboard --"
if [ -f /tmp/exam_page.html ]; then
  if grep -q "YOUR NAME HERE" /tmp/exam_page.html; then
    echo "  [FAIL] Name not replaced (still shows YOUR NAME HERE)"
  elif [ "$HTTP_CODE" = "200" ]; then
    echo "  [PASS] Name replaced on dashboard"
    SCORE=$((SCORE + 10))
  else
    echo "  [FAIL] Cannot check - website not loaded"
  fi
else
  echo "  [FAIL] Cannot check - website not loaded"
fi

# ── 2. Bucket Policy (10 pts) ──
echo ""
echo "-- [10 pts] Bucket Policy --"
POLICY=$(aws s3api get-bucket-policy --bucket "$BUCKET" --region "$REGION" 2>&1)
if echo "$POLICY" | grep -q "GetObject"; then
  echo "  [PASS] Bucket policy has s3:GetObject"
  SCORE=$((SCORE + 10))
else
  echo "  [FAIL] Bucket policy missing or no GetObject"
fi

# ── 3. IAM Role (15 pts) ──
echo ""
echo "-- [15 pts] IAM Role (least privilege) --"
ROLE_ARN=$(aws lambda get-function-configuration --function-name "$FUNC" --region "$REGION" --query "Role" --output text 2>/dev/null)
if [ -z "$ROLE_ARN" ] || [ "$ROLE_ARN" = "None" ]; then
  echo "  [FAIL] Lambda function not found or no role"
else
  ROLE_NAME=$(echo "$ROLE_ARN" | awk -F'/' '{print $NF}')
  ATTACHED=$(aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query "AttachedPolicies[].PolicyName" --output text 2>/dev/null)
  
  if echo "$ATTACHED" | grep -qi "S3FullAccess\|AdministratorAccess"; then
    echo "  [FAIL] S3FullAccess or AdministratorAccess detected! (-15 pts)"
  else
    # Check inline policies for s3:PutObject
    INLINE_NAMES=$(aws iam list-role-policies --role-name "$ROLE_NAME" --query "PolicyNames" --output text 2>/dev/null)
    HAS_PUT=false
    for PNAME in $INLINE_NAMES; do
      PDOC=$(aws iam get-role-policy --role-name "$ROLE_NAME" --policy-name "$PNAME" --query "PolicyDocument" --output json 2>/dev/null)
      if echo "$PDOC" | grep -q "PutObject"; then
        HAS_PUT=true
      fi
    done
    if $HAS_PUT; then
      echo "  [PASS] Scoped policy with s3:PutObject found"
      SCORE=$((SCORE + 15))
    else
      echo "  [FAIL] Missing s3:PutObject in inline policy"
    fi
  fi
fi

# ── 4. Lambda Function (10 pts) ──
echo ""
echo "-- [10 pts] Lambda Function --"
FUNC_INFO=$(aws lambda get-function-configuration --function-name "$FUNC" --region "$REGION" 2>&1)
if echo "$FUNC_INFO" | grep -q "FunctionArn"; then
  RUNTIME=$(echo "$FUNC_INFO" | python3 -c "import sys,json;print(json.load(sys.stdin).get('Runtime',''))" 2>/dev/null)
  if echo "$RUNTIME" | grep -q "python3"; then
    echo "  [PASS] Function exists, runtime: $RUNTIME"
    SCORE=$((SCORE + 10))
  else
    echo "  [FAIL] Function exists but wrong runtime: $RUNTIME"
  fi
else
  echo "  [FAIL] Function $FUNC not found"
fi

# ── 5. S3 Trigger (10 pts) ──
echo ""
echo "-- [10 pts] S3 Trigger --"
NOTIF=$(aws s3api get-bucket-notification-configuration --bucket "$BUCKET" --region "$REGION" 2>&1)
if echo "$NOTIF" | grep -q "LambdaFunctionConfigurations"; then
  if echo "$NOTIF" | grep -q ".csv"; then
    echo "  [PASS] S3 trigger configured with .csv suffix"
    SCORE=$((SCORE + 10))
  else
    echo "  [FAIL] Trigger exists but suffix filter is not .csv"
  fi
else
  echo "  [FAIL] No Lambda trigger configured on bucket"
fi

# ── 6. Bug Fixes / JSON Output (30 pts) ──
echo ""
echo "-- [30 pts] Bug Fixes (JSON output exists + correct) --"
JSON_URL="${WEBSITE_URL}/${JSON_FILE}"
JSON_CODE=$(curl -s -o /tmp/exam_output.json -w "%{http_code}" --max-time 10 "$JSON_URL" 2>/dev/null)
if [ "$JSON_CODE" = "200" ]; then
  echo "  [PASS] ${JSON_FILE} exists (bugs fixed!)"
  
  # Validate content
  if [ "$SET_NAME" = "A" ]; then
    VALID=$(python3 -c "
import json
d=json.load(open('/tmp/exam_output.json'))
assert 'total_stock' in d and 'total_value' in d and 'items' in d
assert len(d['items'])>0
assert d['total_stock']>0
print('ok')
" 2>/dev/null)
  else
    VALID=$(python3 -c "
import json
d=json.load(open('/tmp/exam_output.json'))
assert 'class_average' in d and 'students' in d
assert len(d['students'])>0
assert d['class_average']>0
print('ok')
" 2>/dev/null)
  fi
  
  if [ "$VALID" = "ok" ]; then
    echo "  [PASS] JSON data is correct and complete"
    SCORE=$((SCORE + 30))
  else
    echo "  [PARTIAL] JSON exists but data may be incomplete (+20)"
    SCORE=$((SCORE + 20))
  fi
else
  echo "  [FAIL] ${JSON_FILE} not found (HTTP $JSON_CODE)"
  echo "         Lambda may not have run or bugs not fixed"
fi

# ── RESULTS ──
echo ""
echo "=============================================="
echo "  SCORE: $SCORE / 100"
echo "=============================================="
echo ""

if [ $SCORE -ge 90 ]; then echo "  Grade: EXCELLENT"
elif [ $SCORE -ge 80 ]; then echo "  Grade: VERY GOOD"
elif [ $SCORE -ge 70 ]; then echo "  Grade: GOOD"
elif [ $SCORE -ge 60 ]; then echo "  Grade: NEEDS IMPROVEMENT"
else echo "  Grade: INCOMPLETE"
fi

echo ""
echo "=============================================="
echo "  Screenshot this output and submit."
echo "=============================================="
